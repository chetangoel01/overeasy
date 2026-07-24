from datetime import timedelta
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import RecipeSlotReservation


class ReservationNotFound(Exception):
    pass


class ReservationService:
    def __init__(self, *, clock: Clock, lifetime: timedelta) -> None:
        self._clock = clock
        self._lifetime = lifetime

    def reserve(
        self,
        database: Session,
        *,
        reservation_id: UUID,
        user_id: UUID,
        import_job_id: UUID,
    ) -> RecipeSlotReservation:
        reservation = RecipeSlotReservation(
            id=reservation_id,
            user_id=user_id,
            import_job_id=import_job_id,
            state="reserved",
            created_at=self._clock.now(),
            expires_at=self._clock.now() + self._lifetime,
        )
        database.add(reservation)
        return reservation

    def consume(self, database: Session, import_job_id: UUID) -> None:
        self._transition(database, import_job_id, destination="consumed")

    def release(self, database: Session, import_job_id: UUID) -> None:
        self._transition(database, import_job_id, destination="released")

    def _transition(
        self,
        database: Session,
        import_job_id: UUID,
        *,
        destination: str,
    ) -> None:
        reservation = database.execute(
            select(RecipeSlotReservation)
            .where(RecipeSlotReservation.import_job_id == import_job_id)
            .with_for_update()
        ).scalar_one_or_none()
        if reservation is None:
            raise ReservationNotFound
        if reservation.state == destination:
            return
        if reservation.state != "reserved":
            raise ValueError(f"cannot transition {reservation.state} to {destination}")
        reservation.state = destination
