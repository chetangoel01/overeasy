from typing import Protocol
from uuid import UUID


class ImportDispatcher(Protocol):
    def enqueue(self, job_id: UUID) -> None: ...


class NoopImportDispatcher:
    def enqueue(self, job_id: UUID) -> None:
        del job_id
