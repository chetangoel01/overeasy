from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Event
from time import sleep
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
    Recipe,
    RecipeSlotReservation,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.imports.maintenance import ImportMaintenanceService
from ladle.imports.outbox import DispatchOutboxService
from ladle.imports.reservations import ReservationService
from ladle.imports.transitions import (
    ImportCancellationService,
    ImportCancellationUnavailable,
)
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


@pytest.mark.integration
def test_sweep_with_nothing_to_reclaim_takes_no_locks_and_releases_nothing(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))

    with Session(engine) as database, database.begin():
        released = ImportMaintenanceService(
            clock=clock,
            stale_after=timedelta(hours=1),
        ).release_expired_reservations(database)

    assert released == 0
    engine.dispose()


@pytest.mark.integration
def test_sweep_marks_completed_jobs_consumed_and_skips_consumed_reservations(
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
                platform_video_id="maintenance-states",
                canonical_url="https://www.youtube.com/watch?v=maintenance-states",
                source_revision="1",
                source_metadata={},
            )
        )
        database.flush()
        completed = seed_reserved_job(
            database,
            source_id=source_id,
            status="ready",
            suffix="completed",
            updated_at=clock.now() - timedelta(hours=2),
        )
        already_consumed = seed_reserved_job(
            database,
            source_id=source_id,
            status="parsing",
            suffix="consumed",
            updated_at=clock.now() - timedelta(hours=2),
        )
        completed_job = database.get(ImportJob, completed)
        assert completed_job is not None
        recipe_id = uuid4()
        database.add(
            Recipe(
                id=recipe_id,
                user_id=completed_job.user_id,
                title="Completed import",
                description="",
                source="youtube",
                original_url="https://www.youtube.com/watch?v=maintenance-states",
                servings=1,
                favorite=False,
                review_status="ready",
                revision=1,
                created_at=clock.now(),
                updated_at=clock.now(),
            )
        )
        database.flush()
        completed_job.current_recipe_id = recipe_id
        consumed_reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == already_consumed
            )
        )
        assert consumed_reservation is not None
        consumed_reservation.state = "consumed"

    with Session(engine) as database, database.begin():
        released = ImportMaintenanceService(
            clock=clock,
            stale_after=timedelta(hours=1),
        ).release_expired_reservations(database)

    # The completed job keeps its recipe: its expired reservation is marked
    # consumed, not released, and an already-consumed reservation is untouched.
    assert released == 0
    with Session(engine) as database:
        states = dict(
            database.execute(
                select(
                    RecipeSlotReservation.import_job_id,
                    RecipeSlotReservation.state,
                )
            ).all()
        )
        assert states[completed] == "consumed"
        assert states[already_consumed] == "consumed"
        completed_job = database.get(ImportJob, completed)
        assert completed_job is not None
        assert completed_job.status == "ready"

    engine.dispose()


@pytest.mark.integration
def test_sweep_does_not_deadlock_with_a_concurrent_cancellation(
    clean_postgres_url: str,
) -> None:
    """The sweep must take the import-job lock before the reservation lock.

    Every completion path (complete_shared, fail, retry, cancel) locks the
    import_jobs row first and the reservation second. A sweep that grabs the
    reservation lock first and then updates import_jobs closes a lock cycle
    with any of them, and Postgres aborts the whole beat transaction with
    "deadlock detected" (SQLSTATE 40P01).
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="maintenance-deadlock",
                canonical_url="https://www.youtube.com/watch?v=maintenance-deadlock",
                source_revision="1",
                source_metadata={},
            )
        )
        database.flush()
        job_id = seed_reserved_job(
            database,
            source_id=source_id,
            status="parsing",
            suffix="deadlock",
            updated_at=clock.now() - timedelta(hours=2),
        )
        job = database.get(ImportJob, job_id)
        assert job is not None
        user_id = job.user_id

    swept = Event()
    cancellation = ImportCancellationService(
        clock=clock,
        reservations=ReservationService(clock=clock, lifetime=timedelta(hours=1)),
    )

    def sweep() -> int:
        with Session(engine) as database, database.begin():
            released = ImportMaintenanceService(
                clock=clock,
                stale_after=timedelta(hours=1),
            ).release_expired_reservations(database)
            swept.set()
            # Hold the transaction open long enough for the cancellation to
            # take whatever locks are still free, then commit (flushing the
            # sweep's pending import_jobs update).
            sleep(2.0)
        return released

    def cancel() -> type[Exception] | None:
        assert swept.wait(timeout=30)
        try:
            with Session(engine) as database, database.begin():
                cancellation.cancel(database, user_id=user_id, job_id=job_id)
        except ImportCancellationUnavailable:
            return ImportCancellationUnavailable
        return None

    with ThreadPoolExecutor(max_workers=2) as pool:
        sweep_result = pool.submit(sweep)
        cancel_result = pool.submit(cancel)
        released = sweep_result.result(timeout=30)
        cancel_outcome = cancel_result.result(timeout=30)

    # The sweep saw the stale job and won the race; the cancellation, blocked
    # behind the job lock rather than deadlocking, found the job already
    # failed once the sweep committed.
    assert released == 1
    assert cancel_outcome is ImportCancellationUnavailable
    with Session(engine) as database:
        job = database.get(ImportJob, job_id)
        reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == job_id
            )
        )
        assert job is not None and job.status == "failed"
        assert reservation is not None and reservation.state == "released"

    engine.dispose()
