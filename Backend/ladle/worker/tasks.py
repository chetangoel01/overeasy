import logging
from collections.abc import Callable
from dataclasses import asdict
from random import SystemRandom
from time import perf_counter
from uuid import UUID

import httpx
from billiard.exceptions import SoftTimeLimitExceeded  # type: ignore[import-untyped]
from celery import Task
from kombu.exceptions import (  # type: ignore[import-untyped]
    OperationalError as KombuOperationalError,
)
from redis.exceptions import RedisError
from sqlalchemy.exc import (
    InterfaceError as SQLAlchemyInterfaceError,
)
from sqlalchemy.exc import (
    OperationalError as SQLAlchemyOperationalError,
)
from sqlalchemy.exc import (
    TimeoutError as SQLAlchemyTimeoutError,
)

from ladle.acquisition.errors import ProviderTransientError
from ladle.cache.claims import ClaimLost
from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.imports.dispatcher import (
    PROCESS_IMPORT_TASK,
    CeleryImportDispatcher,
)
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.observability.structured_logging import log_context
from ladle.privacy.retention import RETENTION_SWEEP_TASK
from ladle.worker.app import celery_app
from ladle.worker.runtime import (
    runtime_dispatch_outbox,
    runtime_maintenance,
    runtime_metrics,
    runtime_object_deletion_processor,
    runtime_object_storage,
    runtime_operational_metrics,
    runtime_orchestrator,
    runtime_retention,
    runtime_sessions,
)

_RANDOM = SystemRandom()
LOGGER = logging.getLogger(__name__)
_RETRYABLE_IMPORT_FAILURES = (
    TimeoutError,
    ConnectionError,
    SoftTimeLimitExceeded,
    httpx.TransportError,
    RedisError,
    KombuOperationalError,
    SQLAlchemyInterfaceError,
    SQLAlchemyOperationalError,
    SQLAlchemyTimeoutError,
    ProviderTransientError,
    ClaimLost,
)


def retry_countdown(
    *,
    retry_number: int,
    base_seconds: int,
    maximum_seconds: int,
    jitter_seconds: int,
    jitter: Callable[[int], float] | None = None,
) -> int:
    exponential = min(maximum_seconds, base_seconds * (2 ** max(0, retry_number - 1)))
    jitter_value = (
        jitter(jitter_seconds)
        if jitter is not None
        else float(_RANDOM.uniform(0, jitter_seconds))
    )
    return int(exponential + round(jitter_value))


def is_retryable_import_failure(error: BaseException) -> bool:
    """Classify only operational failures that can succeed without code changes."""

    current: BaseException | None = error
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, _RETRYABLE_IMPORT_FAILURES):
            return True
        current = current.__cause__ or current.__context__
    return False


@celery_app.task(  # type: ignore[untyped-decorator]
    name=PROCESS_IMPORT_TASK,
    bind=True,
    acks_late=True,
    reject_on_worker_lost=True,
)
def process_import(task: Task, job_id: str) -> str:
    settings = Settings()
    stable_id = UUID(job_id)
    started = perf_counter()
    attempts = task.request.retries + 1
    runtime_metrics().set_operational(
        "ladle_worker_last_seen_timestamp_seconds",
        SystemClock().now().timestamp(),
    )
    with log_context(
        job_id=job_id,
        retry_number=attempts,
        stage="orchestration",
    ):
        try:
            outcome = runtime_orchestrator().process(stable_id)
        except Exception as error:
            duration_ms = round((perf_counter() - started) * 1000, 3)
            retryable = is_retryable_import_failure(error)
            retries_exhausted = (
                task.request.retries >= settings.celery_import_max_retries
            )
            if not retryable or retries_exhausted:
                failure_code = (
                    "workerRetriesExhausted"
                    if retryable
                    else f"workerNonRetryable:{type(error).__name__}"
                )
                runtime_dispatch_outbox().dead_letter_job(
                    stable_id,
                    failure_code=failure_code,
                    attempts=attempts,
                )
                LOGGER.error(
                    (
                        "Import task exhausted retries"
                        if retryable
                        else "Import task failed permanently"
                    ),
                    extra={
                        "job_id": job_id,
                        "retry_number": attempts,
                        "duration_ms": duration_ms,
                        "terminal_result": "deadLettered",
                        "exception_type": type(error).__name__,
                        "failure_code": failure_code,
                    },
                )
                runtime_metrics().observe_import(
                    "failed",
                    perf_counter() - started,
                )
                return "failed"
            runtime_dispatch_outbox().record_retry(
                stable_id,
                failure_code=type(error).__name__,
            )
            runtime_metrics().record_worker_retry(_retry_reason(error))
            LOGGER.warning(
                "Import task will retry",
                extra={
                    "job_id": job_id,
                    "retry_number": attempts,
                    "duration_ms": duration_ms,
                    "terminal_result": "retrying",
                    "exception_type": type(error).__name__,
                },
            )
            raise task.retry(
                exc=error,
                max_retries=settings.celery_import_max_retries,
                countdown=retry_countdown(
                    retry_number=attempts,
                    base_seconds=settings.celery_import_retry_base_seconds,
                    maximum_seconds=settings.celery_import_retry_maximum_seconds,
                    jitter_seconds=settings.celery_import_retry_jitter_seconds,
                ),
            ) from error
        LOGGER.info(
            "Import task completed",
            extra={
                "job_id": job_id,
                "retry_number": attempts,
                "duration_ms": round((perf_counter() - started) * 1000, 3),
                "terminal_result": outcome.value,
            },
        )
        import_status = (
            "failed"
            if outcome.value == "failed"
            else "needsReview"
            if "review" in outcome.value.casefold()
            else "ready"
        )
        runtime_metrics().observe_import(
            import_status,
            perf_counter() - started,
        )
        return outcome.value


def _retry_reason(error: Exception) -> str:
    name = type(error).__name__.casefold()
    if "timeout" in name:
        return "providerTimeout"
    if "connection" in name or "broker" in name:
        return "broker"
    return "transient"


@celery_app.task(  # type: ignore[untyped-decorator]
    name=RELEASE_EXPIRED_RESERVATIONS_TASK,
    acks_late=True,
    reject_on_worker_lost=True,
)
def release_expired_reservations() -> int:
    """Recover worker loss, drain durable dispatches, and reclaim slots."""

    sessions = runtime_sessions()
    with sessions() as database, database.begin():
        released = runtime_maintenance().release_expired_reservations(database)
        runtime_dispatch_outbox().recover_abandoned(database)
        runtime_operational_metrics().capture(database)
        runtime_metrics().set_operational(
            "ladle_beat_last_seen_timestamp_seconds",
            SystemClock().now().timestamp(),
        )
    runtime_dispatch_outbox().dispatch_pending(
        CeleryImportDispatcher(celery_app),
    )
    return released


@celery_app.task(  # type: ignore[untyped-decorator]
    name=RETENTION_SWEEP_TASK,
    acks_late=True,
    reject_on_worker_lost=True,
)
def sweep_privacy_retention() -> dict[str, int]:
    sessions = runtime_sessions()
    with sessions() as database, database.begin():
        outcome = runtime_retention().sweep(database)
    deleted_objects = 0
    storage = runtime_object_storage()
    if storage is not None:
        with sessions() as database, database.begin():
            deleted_objects = runtime_object_deletion_processor().process(
                database,
                storage=storage,
            )
    return {**asdict(outcome), "deleted_objects": deleted_objects}
