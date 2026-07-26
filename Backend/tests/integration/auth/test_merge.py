from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.auth.merge import AccountMergeService
from ladle.auth.tokens import RefreshTokenCodec
from ladle.db.models import (
    AppleIdentity,
    AuthSession,
    Device,
    ImportJob,
    ImportQuotaEvent,
    Recipe,
    RecipeChange,
    RecipeSlotReservation,
    User,
    UserSyncState,
)
from ladle.db.session import build_engine
from tests.integration.auth.test_sessions import service
from tests.integration.imports.test_reservations import seed_saved_recipe
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_user(database: Session, *, kind: str, now: datetime) -> UUID:
    user_id = uuid4()
    database.add(User(id=user_id, kind=kind, created_at=now))
    database.add(UserSyncState(user_id=user_id, next_sequence=1))
    database.flush()
    return user_id


@pytest.mark.integration
def test_first_apple_sign_in_upgrades_guest_and_revokes_guest_sessions(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    sessions = service(clock)
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())
        device = Device(
            id=uuid4(),
            user_id=guest_id,
            installation_id="first-apple-device",
            attestation_state="development",
            created_at=clock.now(),
            last_seen_at=clock.now(),
        )
        database.add(device)
        database.flush()
        guest_tokens = sessions.create(
            database,
            user_id=guest_id,
            device_id=device.id,
        )

    with Session(engine) as database, database.begin():
        destination_id = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="stable-first-subject",
            idempotency_key="first-upgrade",
        )

    assert destination_id == guest_id
    with Session(engine) as database:
        user = database.get(User, guest_id)
        identity = database.get(AppleIdentity, "stable-first-subject")
        stored_session = database.get(
            AuthSession,
            RefreshTokenCodec().session_id(guest_tokens.refresh_token or ""),
        )
        assert user is not None
        assert user.kind == "apple"
        assert identity is not None
        assert identity.user_id == guest_id
        assert stored_session is not None
        assert stored_session.revoked_at == clock.now()

    engine.dispose()


@pytest.mark.integration
def test_concurrent_merge_retry_emits_destination_changes_once(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    database_sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)
    with database_sessions.begin() as database:
        guest_id = seed_user(database, kind="guest", now=clock.now())
        destination_id = seed_user(database, kind="apple", now=clock.now())
        database.add(
            AppleIdentity(
                apple_sub="concurrent-apple-subject",
                user_id=destination_id,
                created_at=clock.now(),
            )
        )
        seed_saved_recipe(database, user_id=guest_id, index=1)

    rendezvous = Barrier(3)

    def merge_once() -> UUID:
        with database_sessions.begin() as database:
            rendezvous.wait()
            return merger.merge(
                database,
                guest_user_id=guest_id,
                apple_subject="concurrent-apple-subject",
                idempotency_key="same-concurrent-attempt",
            )

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(merge_once)
        second = executor.submit(merge_once)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]

    assert results == [destination_id, destination_id]
    with database_sessions() as database:
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeChange)
                .where(RecipeChange.user_id == destination_id)
            )
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_existing_apple_account_merge_preserves_data_and_is_idempotent(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    sessions = service(clock)
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())
        destination_id = seed_user(database, kind="apple", now=clock.now())
        database.add(
            AppleIdentity(
                apple_sub="existing-apple-subject",
                user_id=destination_id,
                created_at=clock.now(),
            )
        )
        device = Device(
            id=uuid4(),
            user_id=guest_id,
            installation_id="merge-device",
            attestation_state="development",
            created_at=clock.now(),
            last_seen_at=clock.now(),
        )
        database.add(device)
        seed_saved_recipe(database, user_id=guest_id, index=1)
        seed_saved_recipe(database, user_id=destination_id, index=2)
        database.flush()
        guest_recipe_id = database.scalar(
            select(Recipe.id).where(Recipe.user_id == guest_id)
        )
        assert guest_recipe_id is not None
        job_id = uuid4()
        database.add(
            ImportJob(
                id=job_id,
                user_id=guest_id,
                source_url="https://youtu.be/merged-job",
                canonical_url="https://www.youtube.com/watch?v=merged-job",
                source="youtube",
                status="ready",
                stage="completed",
                retry_count=0,
                bypass_cache=False,
                current_recipe_id=guest_recipe_id,
                idempotency_key="merged-job",
                created_at=clock.now(),
                updated_at=clock.now(),
                completed_at=clock.now(),
            )
        )
        database.flush()
        database.add(
            RecipeSlotReservation(
                id=uuid4(),
                user_id=guest_id,
                import_job_id=job_id,
                state="consumed",
                created_at=clock.now(),
                expires_at=clock.now() + timedelta(hours=1),
            )
        )
        database.add(
            ImportQuotaEvent(
                id=uuid4(),
                user_id=guest_id,
                import_job_id=job_id,
                operation="submit",
                event_key=f"{job_id}:submit",
                occurred_at=clock.now(),
            )
        )
        guest_tokens = sessions.create(
            database,
            user_id=guest_id,
            device_id=device.id,
        )

    with Session(engine) as database, database.begin():
        first = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="existing-apple-subject",
            idempotency_key="merge-attempt",
        )
    with Session(engine) as database, database.begin():
        second = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="existing-apple-subject",
            idempotency_key="merge-attempt",
        )

    assert first == second == destination_id
    with Session(engine) as database:
        guest = database.get(User, guest_id)
        moved_recipe = database.get(Recipe, guest_recipe_id)
        moved_job = database.get(ImportJob, job_id)
        moved_reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == job_id
            )
        )
        moved_device = database.scalar(
            select(Device).where(Device.installation_id == "merge-device")
        )
        moved_quota = database.scalar(
            select(ImportQuotaEvent).where(ImportQuotaEvent.import_job_id == job_id)
        )
        old_session_id = RefreshTokenCodec().session_id(
            guest_tokens.refresh_token or ""
        )
        old_session = database.get(AuthSession, old_session_id)
        assert guest is not None
        assert guest.merged_into_user_id == destination_id
        assert moved_recipe is not None
        assert moved_recipe.user_id == destination_id
        assert moved_job is not None
        assert moved_job.user_id == destination_id
        assert moved_reservation is not None
        assert moved_reservation.user_id == destination_id
        assert moved_device is not None
        assert moved_device.user_id == destination_id
        assert moved_quota is not None
        assert moved_quota.user_id == destination_id
        assert old_session is not None
        assert old_session.revoked_at == clock.now()
        assert (
            database.scalar(
                select(func.count())
                .select_from(Recipe)
                .where(Recipe.user_id == destination_id)
            )
            == 2
        )
        destination_changes = list(
            database.scalars(
                select(RecipeChange).where(RecipeChange.user_id == destination_id)
            )
        )
        assert [change.recipe_id for change in destination_changes] == [guest_recipe_id]
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeChange)
                .where(RecipeChange.user_id == guest_id)
            )
            == 0
        )

    engine.dispose()
