from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ImportJob, RecipeSlotReservation

RELEASE_EXPIRED_RESERVATIONS_TASK = "ladle.imports.release_expired_reservations"


class ImportMaintenanceService:
    def __init__(self, *, clock: Clock, stale_after: timedelta) -> None:
        self._clock = clock
        self._stale_after = stale_after

    def release_expired_reservations(self, database: Session) -> int:
        now = self._clock.now()
        rows = list(
            database.execute(
                select(RecipeSlotReservation, ImportJob)
                .join(
                    ImportJob,
                    ImportJob.id == RecipeSlotReservation.import_job_id,
                )
                .where(
                    RecipeSlotReservation.state == "reserved",
                    RecipeSlotReservation.expires_at <= now,
                )
                .with_for_update(of=RecipeSlotReservation)
            ).all()
        )
        released = 0
        for reservation, job in rows:
            terminal = job.status in {"failed", "ready", "needsReview"}
            stale = (
                job.status == "parsing" and job.updated_at <= now - self._stale_after
            )
            if not terminal and not stale:
                continue
            if job.status in {"ready", "needsReview"} and job.current_recipe_id:
                reservation.state = "consumed"
                continue
            reservation.state = "released"
            released += 1
            if stale:
                job.status = "failed"
                job.stage = "failed"
                job.failure_reason = "networkUnavailable"
                job.diagnostic_code = "abandonedImport"
                job.completed_at = now
                job.updated_at = now
                job.correction_notes_encrypted = None
                job.pasted_text_encrypted = None
        return released
