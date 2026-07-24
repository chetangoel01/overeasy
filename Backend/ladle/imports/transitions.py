from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import ImportJob, Recipe
from ladle.imports.reservations import ReservationService


class ImportRetryUnavailable(Exception):
    pass


class ImportRetryService:
    def __init__(
        self,
        *,
        clock: Clock,
        reservations: ReservationService,
        private_text: PrivateTextCipher,
    ) -> None:
        self._clock = clock
        self._reservations = reservations
        self._private_text = private_text

    def retry(
        self,
        database: Session,
        *,
        user_id: UUID,
        job_id: UUID,
        correction_notes: str | None,
        pasted_text: str | None,
    ) -> ImportJob:
        job = database.execute(
            select(ImportJob)
            .where(
                ImportJob.id == job_id,
                ImportJob.user_id == user_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        if job is None or job.status == "parsing":
            raise ImportRetryUnavailable

        if job.candidate_recipe_id is not None:
            candidate = database.get(Recipe, job.candidate_recipe_id)
            job.candidate_recipe_id = None
            database.flush()
            if candidate is not None:
                database.delete(candidate)

        if job.current_recipe_id is None:
            self._reservations.reactivate(database, job.id)
            job.base_recipe_revision = None
        else:
            current = database.get(Recipe, job.current_recipe_id)
            if current is None or current.deleted_at is not None:
                raise ImportRetryUnavailable
            job.base_recipe_revision = current.revision

        job.correction_notes_encrypted = (
            self._private_text.encrypt(correction_notes) if correction_notes else None
        )
        job.pasted_text_encrypted = (
            self._private_text.encrypt(pasted_text) if pasted_text else None
        )
        job.bypass_cache = bool(
            correction_notes or pasted_text or job.current_recipe_id
        )
        job.status = "parsing"
        job.stage = "retryAdmitted"
        job.failure_reason = None
        job.diagnostic_code = None
        job.cache_entry_id = None
        job.completed_at = None
        job.retry_count += 1
        job.updated_at = self._clock.now()
        database.flush()
        return job


class ImportTransitionService:
    def __init__(
        self,
        *,
        clock: Clock,
        reservations: ReservationService,
    ) -> None:
        self._clock = clock
        self._reservations = reservations

    def fail(
        self,
        database: Session,
        *,
        job_id: UUID,
        source_video_id: UUID,
        failure_reason: str,
        diagnostic_code: str,
        include_shared_followers: bool,
    ) -> tuple[UUID, ...]:
        query = select(ImportJob).where(ImportJob.status == "parsing")
        if include_shared_followers:
            query = query.where(
                ImportJob.source_video_id == source_video_id,
                ImportJob.bypass_cache.is_(False),
            )
        else:
            query = query.where(ImportJob.id == job_id)
        jobs = list(database.scalars(query.with_for_update()))
        now = self._clock.now()
        for job in jobs:
            job.status = "failed"
            job.stage = "failed"
            job.failure_reason = failure_reason
            job.diagnostic_code = diagnostic_code
            job.completed_at = now
            job.updated_at = now
            job.correction_notes_encrypted = None
            job.pasted_text_encrypted = None
            self._reservations.release_if_reserved(database, job.id)
        database.flush()
        return tuple(job.id for job in jobs)
