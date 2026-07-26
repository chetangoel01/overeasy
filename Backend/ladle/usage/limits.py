from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from math import floor

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ProviderAttempt, ProviderBudgetWindow


class UsageLimitExceeded(Exception):
    pass


@dataclass(frozen=True)
class BudgetReservation:
    window_started_at: datetime
    units: Decimal
    expires_at: datetime


class UsageLimitService:
    """Serialize spend reservations in PostgreSQL across every worker."""

    def __init__(
        self,
        *,
        clock: Clock,
        window: timedelta,
        max_billed_units: Decimal,
        reservation_lifetime: timedelta = timedelta(minutes=30),
    ) -> None:
        if window <= timedelta(0) or reservation_lifetime <= timedelta(0):
            raise ValueError("budget timing must be positive")
        if not max_billed_units.is_finite() or max_billed_units <= 0:
            raise ValueError("provider budget must be finite and positive")
        self._clock = clock
        self._window = window
        self._max_billed_units = max_billed_units
        self._reservation_lifetime = reservation_lifetime

    def reserve(
        self,
        database: Session,
        *,
        estimated_units: Decimal,
    ) -> BudgetReservation:
        self._validate_units(estimated_units)
        now = self._clock.now().astimezone(UTC)
        started_at = self._window_start(now)
        ends_at = started_at + self._window
        database.execute(
            insert(ProviderBudgetWindow)
            .values(
                window_started_at=started_at,
                window_ends_at=ends_at,
                maximum_units=self._max_billed_units,
                spent_units=Decimal(0),
                reserved_units=Decimal(0),
                updated_at=now,
            )
            .on_conflict_do_nothing(
                index_elements=[ProviderBudgetWindow.window_started_at]
            )
        )
        window = database.execute(
            select(ProviderBudgetWindow)
            .where(ProviderBudgetWindow.window_started_at == started_at)
            .with_for_update()
        ).scalar_one()
        effective_limit = min(
            Decimal(window.maximum_units),
            self._max_billed_units,
        )
        window.maximum_units = effective_limit
        self._release_expired(database, window=window, now=now)
        if (
            Decimal(window.spent_units)
            + Decimal(window.reserved_units)
            + estimated_units
            > effective_limit
        ):
            raise UsageLimitExceeded("provider budget is fully reserved")
        window.reserved_units = Decimal(window.reserved_units) + estimated_units
        window.updated_at = now
        return BudgetReservation(
            window_started_at=started_at,
            units=estimated_units,
            expires_at=now + self._reservation_lifetime,
        )

    def reconcile(
        self,
        database: Session,
        *,
        window_started_at: datetime,
        reserved_units: Decimal,
        actual_units: Decimal,
    ) -> None:
        self._validate_units(reserved_units)
        self._validate_units(actual_units)
        window = database.execute(
            select(ProviderBudgetWindow)
            .where(ProviderBudgetWindow.window_started_at == window_started_at)
            .with_for_update()
        ).scalar_one()
        if Decimal(window.reserved_units) < reserved_units:
            raise RuntimeError("provider budget reservation accounting underflow")
        window.reserved_units = Decimal(window.reserved_units) - reserved_units
        window.spent_units = Decimal(window.spent_units) + actual_units
        window.updated_at = self._clock.now().astimezone(UTC)

    def ensure_available(self, database: Session) -> None:
        """Compatibility check for callers that cannot reserve yet."""

        now = self._clock.now().astimezone(UTC)
        window = database.get(ProviderBudgetWindow, self._window_start(now))
        if window is not None and (
            Decimal(window.spent_units) + Decimal(window.reserved_units)
            >= min(Decimal(window.maximum_units), self._max_billed_units)
        ):
            raise UsageLimitExceeded("provider budget is exhausted")

    def _release_expired(
        self,
        database: Session,
        *,
        window: ProviderBudgetWindow,
        now: datetime,
    ) -> None:
        attempts = list(
            database.scalars(
                select(ProviderAttempt)
                .where(
                    ProviderAttempt.budget_window_started_at
                    == window.window_started_at,
                    ProviderAttempt.reserved_units > 0,
                    ProviderAttempt.reservation_expires_at <= now,
                )
                .with_for_update(skip_locked=True)
            )
        )
        released = sum(
            (Decimal(attempt.reserved_units) for attempt in attempts),
            start=Decimal(0),
        )
        for attempt in attempts:
            attempt.reserved_units = Decimal(0)
            attempt.reservation_expires_at = None
        if released:
            current = Decimal(window.reserved_units)
            if current < released:
                raise RuntimeError("provider budget expiration accounting underflow")
            window.reserved_units = current - released

    def _window_start(self, value: datetime) -> datetime:
        seconds = self._window.total_seconds()
        epoch = floor(value.timestamp() / seconds) * seconds
        return datetime.fromtimestamp(epoch, UTC)

    @staticmethod
    def _validate_units(value: Decimal) -> None:
        if not value.is_finite() or value < 0:
            raise ValueError("provider budget units must be finite and nonnegative")
