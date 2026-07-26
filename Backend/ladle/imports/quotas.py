from datetime import UTC, datetime, timedelta
from math import ceil
from typing import Literal
from uuid import UUID, uuid4

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ImportQuotaEvent, User


class ImportQuotaExceeded(Exception):
    def __init__(
        self,
        *,
        period: Literal["daily", "monthly"],
        retry_at: datetime,
        now: datetime,
    ) -> None:
        super().__init__(f"{period} import quota exceeded")
        self.period = period
        self.retry_at = retry_at
        self.retry_after_seconds = max(
            1,
            ceil((retry_at - now).total_seconds()),
        )


class ImportQuotaService:
    """Atomically account for provider-capable import submissions per user."""

    def __init__(
        self,
        *,
        clock: Clock,
        daily_limit: int,
        monthly_limit: int,
    ) -> None:
        if daily_limit <= 0 or monthly_limit < daily_limit:
            raise ValueError("import quotas must be positive and monthly >= daily")
        self._clock = clock
        self._daily_limit = daily_limit
        self._monthly_limit = monthly_limit

    def consume(
        self,
        database: Session,
        *,
        user_id: UUID,
        import_job_id: UUID,
        operation: Literal["submit", "retry"],
        event_key: str,
    ) -> None:
        if self._exists(database, user_id=user_id, event_key=event_key):
            return
        database.execute(
            select(User.id).where(User.id == user_id).with_for_update()
        ).scalar_one()
        if self._exists(database, user_id=user_id, event_key=event_key):
            return

        now = self._clock.now().astimezone(UTC)
        day_start = now.replace(hour=0, minute=0, second=0, microsecond=0)
        month_start = day_start.replace(day=1)
        next_day = day_start + timedelta(days=1)
        # Construct the monthly boundary without assuming every month has the
        # same length.
        next_month = (
            month_start.replace(year=month_start.year + 1, month=1)
            if month_start.month == 12
            else month_start.replace(month=month_start.month + 1)
        )
        daily = self._count(database, user_id=user_id, since=day_start)
        monthly = self._count(database, user_id=user_id, since=month_start)
        if monthly >= self._monthly_limit:
            raise ImportQuotaExceeded(
                period="monthly",
                retry_at=next_month,
                now=now,
            )
        if daily >= self._daily_limit:
            raise ImportQuotaExceeded(period="daily", retry_at=next_day, now=now)

        database.add(
            ImportQuotaEvent(
                id=uuid4(),
                user_id=user_id,
                import_job_id=import_job_id,
                operation=operation,
                event_key=event_key,
                occurred_at=now,
            )
        )
        database.flush()

    @staticmethod
    def _exists(database: Session, *, user_id: UUID, event_key: str) -> bool:
        return (
            database.scalar(
                select(ImportQuotaEvent.id).where(
                    ImportQuotaEvent.user_id == user_id,
                    ImportQuotaEvent.event_key == event_key,
                )
            )
            is not None
        )

    @staticmethod
    def _count(database: Session, *, user_id: UUID, since: datetime) -> int:
        value = database.scalar(
            select(func.count())
            .select_from(ImportQuotaEvent)
            .where(
                ImportQuotaEvent.user_id == user_id,
                ImportQuotaEvent.occurred_at >= since,
            )
        )
        return int(value or 0)
