from collections.abc import Callable
from dataclasses import asdict
from random import SystemRandom
from uuid import UUID

from celery import Task

from ladle.config import Settings
from ladle.imports.dispatcher import (
    PROCESS_IMPORT_TASK,
    CeleryImportDispatcher,
)
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.privacy.retention import RETENTION_SWEEP_TASK
from ladle.worker.app import celery_app
from ladle.worker.runtime import (
    runtime_dispatch_outbox,
    runtime_maintenance,
    runtime_object_deletion_processor,
    runtime_object_storage,
    runtime_orchestrator,
    runtime_retention,
    runtime_sessions,
)

_RANDOM = SystemRandom()


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


@celery_app.task(  # type: ignore[untyped-decorator]
    name=PROCESS_IMPORT_TASK,
    bind=True,
    acks_late=True,
    reject_on_worker_lost=True,
)
def process_import(task: Task, job_id: str) -> str:
    settings = Settings()
    stable_id = UUID(job_id)
    try:
        outcome = runtime_orchestrator().process(stable_id)
    except Exception as error:
        attempts = task.request.retries + 1
        if task.request.retries >= settings.celery_import_max_retries:
            runtime_dispatch_outbox().dead_letter_job(
                stable_id,
                failure_code="workerRetriesExhausted",
                attempts=attempts,
            )
            return "failed"
        runtime_dispatch_outbox().record_retry(
            stable_id,
            failure_code=type(error).__name__,
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
    return outcome.value


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
