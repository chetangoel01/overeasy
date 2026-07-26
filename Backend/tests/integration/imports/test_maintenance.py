from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.db.models import (
    ExtractionClaim,
    ImportDeadLetter,
    ImportDispatchOutbox,
    ImportJob,
    RecipeSlotReservation,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.imports.maintenance import ImportMaintenanceService
from ladle.imports.outbox import DispatchOutboxService
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_reserved_job(
    database: Session,
    *,
    source_id: UUID,
    status: str,
    suffix: str,
    updated_at: datetime,
) -> UUID:
    user_id = seed_user(database)
    job_id = uuid4()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url="https://youtu.be/maintenance",
            canonical_url="https://www.youtube.com/watch?v=maintenance",
            source="youtube",
            status=status,
            stage=status,
            failure_reason="parserUnavailable" if status == "failed" else None,
            retry_count=0,
            bypass_cache=False,
            idempotency_key=f"maintenance-{suffix}",
            updated_at=updated_at,
        )
    )
    database.add(
        RecipeSlotReservation(
            id=uuid4(),
            user_id=user_id,
            import_job_id=job_id,
            state="reserved",
            created_at=updated_at,
            expires_at=updated_at + timedelta(minutes=30),
        )
    )
    database.flush()
    return job_id


@pytest.mark.integration
def test_expired_slots_release_only_for_terminal_or_irrecoverably_stale_jobs(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="maintenance",
                canonical_url="https://www.youtube.com/watch?v=maintenance",
                source_revision="1",
                source_metadata={},
            )
        )
        database.flush()
        terminal = seed_reserved_job(
            database,
            source_id=source_id,
            status="failed",
            suffix="terminal",
            updated_at=clock.now() - timedelta(hours=2),
        )
        stale = seed_reserved_job(
            database,
            source_id=source_id,
            status="parsing",
            suffix="stale",
            updated_at=clock.now() - timedelta(hours=2),
        )
        fresh = seed_reserved_job(
            database,
            source_id=source_id,
            status="parsing",
            suffix="fresh",
            updated_at=clock.now() - timedelta(minutes=31),
        )

    with Session(engine) as database, database.begin():
        released = ImportMaintenanceService(
            clock=clock,
            stale_after=timedelta(hours=1),
        ).release_expired_reservations(database)
    assert released == 2

    with Session(engine) as database:
        states = dict(
            database.execute(
                select(
                    RecipeSlotReservation.import_job_id,
                    RecipeSlotReservation.state,
                )
            ).all()
        )
        assert states[terminal] == "released"
        assert states[stale] == "released"
        assert states[fresh] == "reserved"
        stale_job = database.get(ImportJob, stale)
        assert stale_job is not None
        assert stale_job.status == "failed"
        assert stale_job.failure_reason == "networkUnavailable"

    engine.dispose()


@pytest.mark.integration
def test_abandoned_jobs_redispatch_then_dead_letter_after_repeated_worker_loss(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    stale_at = clock.now() - timedelta(minutes=40)
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="recovery",
                canonical_url="https://www.youtube.com/watch?v=recovery",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_reserved_job(
            database,
            source_id=source_id,
            status="parsing",
            suffix="recovery",
            updated_at=stale_at,
        )
        database.add(
            ImportDispatchOutbox(
                import_job_id=job_id,
                available_at=stale_at,
                dispatched_at=stale_at,
                dispatch_count=1,
                created_at=stale_at,
                updated_at=stale_at,
            )
        )
        database.add(
            ExtractionClaim(
                id=uuid4(),
                source_video_id=source_id,
                owner_job_id=job_id,
                claim_version=1,
                lease_expires_at=stale_at,
                heartbeat_at=stale_at,
            )
        )

    service = DispatchOutboxService(
        session_factory=sessions,
        clock=clock,
        stale_after=timedelta(minutes=32),
        maximum_dispatches=2,
    )
    with Session(engine) as database, database.begin():
        recovered = service.recover_abandoned(database)
    assert recovered == (job_id,)

    with Session(engine) as database, database.begin():
        job = database.get(ImportJob, job_id)
        outbox = database.get(ImportDispatchOutbox, job_id)
        claim = database.scalar(
            select(ExtractionClaim).where(ExtractionClaim.owner_job_id == job_id)
        )
        assert job is not None and job.stage == "recoveryQueued"
        assert outbox is not None and outbox.dispatched_at is None
        assert claim is not None and claim.released_at == clock.now()
        outbox.dispatched_at = clock.now()
        outbox.dispatch_count = 2
        job.updated_at = stale_at

    with Session(engine) as database, database.begin():
        recovered = service.recover_abandoned(database)
    assert recovered == ()

    with Session(engine) as database:
        job = database.get(ImportJob, job_id)
        dead = database.scalar(
            select(ImportDeadLetter).where(ImportDeadLetter.import_job_id == job_id)
        )
        reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == job_id
            )
        )
        assert job is not None
        assert job.status == "failed"
        assert job.failure_reason == "networkUnavailable"
        assert job.diagnostic_code == "workerDispatchesExhausted"
        assert dead is not None and dead.attempts == 2
        assert reservation is not None and reservation.state == "released"

    engine.dispose()
