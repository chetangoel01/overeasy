from datetime import timedelta
from typing import Protocol, cast

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import (
    ImportDeadLetter,
    ImportDispatchOutbox,
    ImportJob,
    ObjectDeletionQueue,
    ProviderBudgetWindow,
)
from ladle.observability.metrics import MetricsRegistry


class QueueDepth(Protocol):
    def llen(self, name: str) -> object: ...


class OperationalMetricsCollector:
    def __init__(
        self,
        *,
        clock: Clock,
        metrics: MetricsRegistry,
        stale_after: timedelta,
        broker: QueueDepth | None = None,
        queue_name: str = "celery",
    ) -> None:
        self._clock = clock
        self._metrics = metrics
        self._stale_after = stale_after
        self._broker = broker
        self._queue_name = queue_name

    def capture(self, database: Session) -> None:
        now = self._clock.now()
        stuck = database.scalar(
            select(func.count())
            .select_from(ImportJob)
            .where(
                ImportJob.status == "parsing",
                ImportJob.updated_at <= now - self._stale_after,
            )
        )
        oldest = database.scalar(
            select(func.min(ImportDispatchOutbox.available_at)).where(
                ImportDispatchOutbox.dispatched_at.is_(None)
            )
        )
        spend = database.execute(
            select(
                func.coalesce(func.sum(ProviderBudgetWindow.spent_units), 0),
                func.coalesce(func.sum(ProviderBudgetWindow.reserved_units), 0),
            ).where(ProviderBudgetWindow.window_ends_at > now)
        ).one()
        dead_letters = database.scalar(
            select(func.count()).select_from(ImportDeadLetter)
        )
        object_failures = database.scalar(
            select(func.count())
            .select_from(ObjectDeletionQueue)
            .where(
                ObjectDeletionQueue.deleted_at.is_(None),
                ObjectDeletionQueue.attempts > 0,
            )
        )
        self._metrics.set_operational("ladle_stuck_jobs", float(stuck or 0))
        self._metrics.set_operational(
            "ladle_oldest_queued_job_age_seconds",
            max(0.0, (now - oldest).total_seconds()) if oldest is not None else 0,
        )
        self._metrics.set_operational(
            "ladle_provider_spend_units",
            float(spend[0]),
        )
        self._metrics.set_operational(
            "ladle_provider_reserved_units",
            float(spend[1]),
        )
        self._metrics.set_operational(
            "ladle_dead_letters",
            float(dead_letters or 0),
        )
        self._metrics.set_operational(
            "ladle_object_deletion_failures",
            float(object_failures or 0),
        )
        if self._broker is not None:
            self._metrics.set_operational(
                "ladle_queue_depth",
                float(
                    cast(
                        str | int | float,
                        self._broker.llen(self._queue_name),
                    )
                ),
            )
