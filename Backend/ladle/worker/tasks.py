from uuid import UUID

from ladle.imports.dispatcher import PROCESS_IMPORT_TASK
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.worker.app import celery_app
from ladle.worker.runtime import (
    runtime_maintenance,
    runtime_orchestrator,
    runtime_sessions,
)


@celery_app.task(  # type: ignore[untyped-decorator]
    name=PROCESS_IMPORT_TASK,
    acks_late=True,
    reject_on_worker_lost=True,
)
def process_import(job_id: str) -> str:
    outcome = runtime_orchestrator().process(UUID(job_id))
    return outcome.value


@celery_app.task(  # type: ignore[untyped-decorator]
    name=RELEASE_EXPIRED_RESERVATIONS_TASK,
    acks_late=True,
    reject_on_worker_lost=True,
)
def release_expired_reservations() -> int:
    """Fail imports whose worker died, and give their recipe slots back."""

    sessions = runtime_sessions()
    with sessions() as database, database.begin():
        return runtime_maintenance().release_expired_reservations(database)
