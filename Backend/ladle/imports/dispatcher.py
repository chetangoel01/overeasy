from typing import Protocol
from uuid import UUID

from celery import Celery

PROCESS_IMPORT_TASK = "ladle.imports.process"


class TaskSender(Protocol):
    def send_task(
        self,
        name: str,
        *,
        args: list[str],
        task_id: str,
    ) -> object: ...


class ImportDispatcher(Protocol):
    def enqueue(self, job_id: UUID) -> None: ...


class NoopImportDispatcher:
    def enqueue(self, job_id: UUID) -> None:
        del job_id


class CeleryImportDispatcher:
    def __init__(self, celery: TaskSender) -> None:
        self._celery = celery

    @classmethod
    def from_broker(cls, broker_url: str) -> "CeleryImportDispatcher":
        return cls(Celery("ladle-api-dispatch", broker=broker_url))

    def enqueue(self, job_id: UUID) -> None:
        self._celery.send_task(
            PROCESS_IMPORT_TASK,
            args=[str(job_id)],
            task_id=f"import:{job_id}",
        )
