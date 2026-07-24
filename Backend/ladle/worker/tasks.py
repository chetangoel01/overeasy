from uuid import UUID

from ladle.imports.dispatcher import PROCESS_IMPORT_TASK
from ladle.worker.app import celery_app
from ladle.worker.runtime import runtime_orchestrator


@celery_app.task(  # type: ignore[untyped-decorator]
    name=PROCESS_IMPORT_TASK,
    acks_late=True,
    reject_on_worker_lost=True,
)
def process_import(job_id: str) -> str:
    outcome = runtime_orchestrator().process(UUID(job_id))
    return outcome.value
