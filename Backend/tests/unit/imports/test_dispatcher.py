from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

from ladle.imports.dispatcher import (
    PROCESS_IMPORT_TASK,
    CeleryImportDispatcher,
)


@dataclass
class RecordingCelery:
    calls: list[dict[str, Any]] = field(default_factory=list)

    def send_task(
        self,
        name: str,
        *,
        args: list[str],
        task_id: str,
    ) -> None:
        self.calls.append({"name": name, "args": args, "task_id": task_id})


def test_celery_dispatch_uses_only_stable_id_and_deterministic_task_id() -> None:
    celery = RecordingCelery()
    dispatcher = CeleryImportDispatcher(celery)
    job_id = uuid4()

    dispatcher.enqueue(job_id)

    assert celery.calls == [
        {
            "name": PROCESS_IMPORT_TASK,
            "args": [str(job_id)],
            "task_id": f"import:{job_id}",
        }
    ]
