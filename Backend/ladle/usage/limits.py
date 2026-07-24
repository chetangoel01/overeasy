from datetime import timedelta
from decimal import Decimal

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ProviderAttempt


class UsageLimitExceeded(Exception):
    pass


class UsageLimitService:
    def __init__(
        self,
        *,
        clock: Clock,
        window: timedelta,
        max_billed_units: Decimal,
    ) -> None:
        self._clock = clock
        self._window = window
        self._max_billed_units = max_billed_units

    def ensure_available(self, database: Session) -> None:
        used = database.scalar(
            select(func.coalesce(func.sum(ProviderAttempt.billed_units), 0)).where(
                ProviderAttempt.status == "completed",
                ProviderAttempt.completed_at >= self._clock.now() - self._window,
            )
        )
        if Decimal(used or 0) >= self._max_billed_units:
            raise UsageLimitExceeded
