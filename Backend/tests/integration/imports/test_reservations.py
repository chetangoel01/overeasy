from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.db.models import (
    ImportJob,
    Recipe,
    RecipeSlotReservation,
)
from ladle.db.session import build_engine
from ladle.imports.admission import AdmissionService
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.recipes.limits import GuestRecipeLimitReached, lock_recipe_capacity
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_saved_recipe(database: Session, *, user_id: UUID, index: int) -> None:
    now = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
    recipe_id = uuid4()
    database.add(
        Recipe(
            id=recipe_id,
            user_id=user_id,
            title=f"Saved {index}",
            description="",
            source="other",
            original_url=f"https://manual.ladle.local/{recipe_id}",
            servings=1,
            favorite=False,
            review_status="ready",
            revision=1,
            created_at=now,
            updated_at=now,
        )
    )


@pytest.mark.integration
def test_parallel_imports_at_nine_recipes_admit_exactly_one(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    admission = AdmissionService(
        parser=SourceIdentityParser(),
        reservations=ReservationService(
            clock=clock,
            lifetime=timedelta(hours=1),
        ),
        clock=clock,
    )

    with sessions.begin() as setup:
        user_id = seed_user(setup)
        for index in range(9):
            seed_saved_recipe(setup, user_id=user_id, index=index)

    rendezvous = Barrier(3)

    def submit(index: int) -> str:
        try:
            with sessions.begin() as database:
                rendezvous.wait()
                admission.admit(
                    database,
                    job_id=uuid4(),
                    user_id=user_id,
                    source_url=(
                        f"https://www.youtube.com/watch?v=parallel-{index:02d}"
                    ),
                    allow_duplicate=False,
                    idempotency_key=f"parallel-{index}",
                )
            return "admitted"
        except GuestRecipeLimitReached:
            return "limited"

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(submit, 1)
        second = executor.submit(submit, 2)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]

    assert sorted(results) == ["admitted", "limited"]
    with sessions() as verification:
        assert verification.scalar(select(func.count()).select_from(ImportJob)) == 1
        assert (
            verification.scalar(
                select(func.count())
                .select_from(RecipeSlotReservation)
                .where(RecipeSlotReservation.state == "reserved")
            )
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_idempotent_submission_reuses_job_and_reservation(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    admission = AdmissionService(
        parser=SourceIdentityParser(),
        reservations=ReservationService(
            clock=clock,
            lifetime=timedelta(hours=1),
        ),
        clock=clock,
    )
    job_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        first = admission.admit(
            database,
            job_id=job_id,
            user_id=user_id,
            source_url="https://youtu.be/idempotent1",
            allow_duplicate=False,
            idempotency_key="same-request",
        )
        second = admission.admit(
            database,
            job_id=uuid4(),
            user_id=user_id,
            source_url="https://youtu.be/idempotent1",
            allow_duplicate=False,
            idempotency_key="same-request",
        )

    assert first.job_id == second.job_id == job_id
    assert first.should_dispatch
    assert not second.should_dispatch
    with Session(engine) as verification:
        assert verification.scalar(select(func.count()).select_from(ImportJob)) == 1
        assert (
            verification.scalar(select(func.count()).select_from(RecipeSlotReservation))
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_reservation_success_consumes_and_terminal_failure_releases(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    reservations = ReservationService(
        clock=clock,
        lifetime=timedelta(hours=1),
    )
    admission = AdmissionService(
        parser=SourceIdentityParser(),
        reservations=reservations,
        clock=clock,
    )

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        success = admission.admit(
            database,
            job_id=uuid4(),
            user_id=user_id,
            source_url="https://youtu.be/reserve-ok1",
            allow_duplicate=False,
            idempotency_key="success",
        )
        failure = admission.admit(
            database,
            job_id=uuid4(),
            user_id=user_id,
            source_url="https://youtu.be/reserve-bad",
            allow_duplicate=False,
            idempotency_key="failure",
        )
        reservations.consume(database, success.job_id)
        reservations.release(database, failure.job_id)
        reservations.consume(database, success.job_id)
        reservations.release(database, failure.job_id)

    with Session(engine) as verification:
        states = dict(
            verification.execute(
                select(
                    RecipeSlotReservation.import_job_id,
                    RecipeSlotReservation.state,
                )
            ).all()
        )
        assert states == {
            success.job_id: "consumed",
            failure.job_id: "released",
        }

    engine.dispose()


@pytest.mark.integration
def test_hidden_reparse_candidate_does_not_consume_a_guest_library_slot(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        for index in range(9):
            seed_saved_recipe(database, user_id=user_id, index=index)
        candidate_id = uuid4()
        now = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
        database.add(
            Recipe(
                id=candidate_id,
                user_id=user_id,
                title="Hidden reparse candidate",
                description="",
                source="other",
                original_url=f"https://manual.ladle.local/{candidate_id}",
                servings=1,
                favorite=False,
                review_status="needsReview",
                revision=1,
                created_at=now,
                updated_at=now,
            )
        )
        database.flush()
        database.add(
            ImportJob(
                id=uuid4(),
                user_id=user_id,
                source_url="https://youtu.be/candidate",
                canonical_url="https://www.youtube.com/watch?v=candidate",
                source="youtube",
                status="needsReview",
                stage="completed",
                retry_count=1,
                bypass_cache=True,
                candidate_recipe_id=candidate_id,
                idempotency_key="candidate-capacity",
                created_at=now,
                updated_at=now,
                completed_at=now,
            )
        )
        database.flush()

        capacity = lock_recipe_capacity(database, user_id)

    assert capacity.saved_recipes == 9
    assert capacity.occupied_slots == 9
    engine.dispose()
