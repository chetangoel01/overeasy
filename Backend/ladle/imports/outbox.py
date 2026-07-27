from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from ladle.clock import Clock
from ladle.db.models import (
    ExtractionClaim,
    ImportDeadLetter,
    ImportDispatchOutbox,
    ImportJob,
    RecipeSlotReservation,
)
from ladle.imports.dispatcher import ImportDispatcher


class DispatchOutboxService:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        clock: Clock,
        stale_after: timedelta,
        maximum_dispatches: int,
    ) -> None:
        if stale_after <= timedelta(0) or maximum_dispatches <= 0:
            raise ValueError("outbox recovery settings must be positive")
        self._sessions = session_factory
        self._clock = clock
        self._stale_after = stale_after
        self._maximum_dispatches = maximum_dispatches

    def queue(self, database: Session, job_id: UUID) -> None:
        now = self._clock.now()
        row = database.get(ImportDispatchOutbox, job_id)
        if row is None:
            database.add(
                ImportDispatchOutbox(
                    import_job_id=job_id,
                    available_at=now,
                    created_at=now,
                    updated_at=now,
                )
            )
            return
        row.available_at = now
        row.dispatched_at = None
        row.last_error = None
        row.updated_at = now

    def ensure_dispatchable(self, database: Session, job: ImportJob) -> bool:
        row = database.execute(
            select(ImportDispatchOutbox)
            .where(ImportDispatchOutbox.import_job_id == job.id)
            .with_for_update()
        ).scalar_one_or_none()
        if row is None:
            self.queue(database, job.id)
            return True
        if row.dispatched_at is None:
            return True
        live_claim = database.scalar(
            select(ExtractionClaim.id).where(
                ExtractionClaim.owner_job_id == job.id,
                ExtractionClaim.released_at.is_(None),
                ExtractionClaim.lease_expires_at > self._clock.now(),
            )
        )
        if live_claim is not None:
            return False
        if job.updated_at > self._clock.now() - self._stale_after:
            return False
        self.queue(database, job.id)
        return True

    def dispatch_one(self, dispatcher: ImportDispatcher, job_id: UUID) -> bool:
        with self._sessions.begin() as database:
            row = database.execute(
                select(ImportDispatchOutbox)
                .where(ImportDispatchOutbox.import_job_id == job_id)
                .with_for_update()
            ).scalar_one_or_none()
            if row is None or row.dispatched_at is not None:
                return False
            return self._send(row, dispatcher)

    def dispatch_pending(
        self,
        dispatcher: ImportDispatcher,
        *,
        limit: int = 100,
    ) -> tuple[UUID, ...]:
        with self._sessions.begin() as database:
            rows = list(
                database.scalars(
                    select(ImportDispatchOutbox)
                    .where(
                        ImportDispatchOutbox.dispatched_at.is_(None),
                        ImportDispatchOutbox.available_at <= self._clock.now(),
                    )
                    .order_by(ImportDispatchOutbox.available_at)
                    .limit(limit)
                    .with_for_update(skip_locked=True)
                )
            )
            return tuple(
                row.import_job_id for row in rows if self._send(row, dispatcher)
            )

    def recover_abandoned(self, database: Session) -> tuple[UUID, ...]:
        now = self._clock.now()
        jobs = list(
            database.scalars(
                select(ImportJob)
                .where(
                    ImportJob.status == "parsing",
                    ImportJob.updated_at <= now - self._stale_after,
                )
                .order_by(ImportJob.updated_at)
                .with_for_update(skip_locked=True)
            )
        )
        recovered: list[UUID] = []
        for job in jobs:
            live_claim = database.scalar(
                select(ExtractionClaim).where(
                    ExtractionClaim.owner_job_id == job.id,
                    ExtractionClaim.released_at.is_(None),
                )
            )
            if live_claim is not None and live_claim.lease_expires_at > now:
                continue
            if live_claim is not None:
                live_claim.released_at = now
            row = database.get(ImportDispatchOutbox, job.id)
            if row is None:
                self.queue(database, job.id)
                row = database.get(ImportDispatchOutbox, job.id)
            assert row is not None
            if row.dispatch_count < self._maximum_dispatches:
                self.queue(database, job.id)
                job.stage = "recoveryQueued"
                job.updated_at = now
                recovered.append(job.id)
                continue
            self._dead_letter(
                database,
                job,
                attempts=row.dispatch_count,
                failure_code="workerDispatchesExhausted",
            )
        return tuple(recovered)

    def record_retry(
        self,
        job_id: UUID,
        *,
        failure_code: str,
    ) -> None:
        with self._sessions.begin() as database:
            job = database.get(ImportJob, job_id)
            if job is None or job.status != "parsing":
                return
            job.stage = "retryScheduled"
            job.diagnostic_code = failure_code[:128]
            job.updated_at = self._clock.now()

    def dead_letter_job(
        self,
        job_id: UUID,
        *,
        failure_code: str,
        attempts: int,
    ) -> None:
        with self._sessions.begin() as database:
            job = database.execute(
                select(ImportJob).where(ImportJob.id == job_id).with_for_update()
            ).scalar_one_or_none()
            if job is None or job.status != "parsing":
                return
            claim = database.scalar(
                select(ExtractionClaim).where(
                    ExtractionClaim.owner_job_id == job.id,
                    ExtractionClaim.released_at.is_(None),
                )
            )
            if claim is not None:
                claim.released_at = self._clock.now()
            self._dead_letter(
                database,
                job,
                attempts=attempts,
                failure_code=failure_code,
            )

    def _send(
        self,
        row: ImportDispatchOutbox,
        dispatcher: ImportDispatcher,
    ) -> bool:
        try:
            dispatcher.enqueue(row.import_job_id)
        except Exception as error:
            row.last_error = type(error).__name__
            row.updated_at = self._clock.now()
            return False
        row.dispatched_at = self._clock.now()
        row.dispatch_count += 1
        row.last_error = None
        row.updated_at = self._clock.now()
        return True

    def _dead_letter(
        self,
        database: Session,
        job: ImportJob,
        *,
        attempts: int,
        failure_code: str,
    ) -> None:
        now = self._clock.now()
        job.status = "failed"
        job.stage = "failed"
        job.failure_reason = "networkUnavailable"
        job.diagnostic_code = failure_code[:128]
        job.completed_at = now
        job.updated_at = now
        job.correction_notes_encrypted = None
        job.pasted_text_encrypted = None
        reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == job.id
            )
        )
        if reservation is not None and reservation.state == "reserved":
            reservation.state = "released"
        existing = database.scalar(
            select(ImportDeadLetter.id).where(ImportDeadLetter.import_job_id == job.id)
        )
        if existing is None:
            database.add(
                ImportDeadLetter(
                    id=uuid4(),
                    import_job_id=job.id,
                    failure_code=failure_code[:128],
                    attempts=attempts,
                    created_at=now,
                )
            )
