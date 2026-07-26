from celery import Celery

from ladle.config import Settings
from ladle.imports.dispatcher import PROCESS_IMPORT_TASK
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.observability.tracing import instrument_worker
from ladle.privacy.retention import RETENTION_SWEEP_TASK


def create_celery_app(settings: Settings | None = None) -> Celery:
    configured = settings or Settings()
    application = Celery(
        "ladle-worker",
        broker=configured.celery_broker_url,
        backend=configured.celery_result_backend,
        include=["ladle.worker.tasks"],
    )
    application.conf.update(
        task_acks_late=True,
        task_reject_on_worker_lost=True,
        task_soft_time_limit=configured.celery_task_soft_time_limit_seconds,
        task_time_limit=configured.celery_task_time_limit_seconds,
        worker_prefetch_multiplier=1,
        broker_connection_retry_on_startup=True,
        task_annotations={
            PROCESS_IMPORT_TASK: {
                "max_retries": configured.celery_import_max_retries,
            }
        },
        task_serializer="json",
        result_serializer="json",
        accept_content=["json"],
        broker_transport_options={
            "visibility_timeout": configured.celery_visibility_timeout_seconds
        },
        result_backend_transport_options={
            "visibility_timeout": configured.celery_visibility_timeout_seconds
        },
        timezone="UTC",
        enable_utc=True,
        beat_schedule={
            "release-expired-reservations": {
                "task": RELEASE_EXPIRED_RESERVATIONS_TASK,
                "schedule": float(configured.import_maintenance_interval_seconds),
                # A sweep that piles up behind a busy worker has nothing to add
                # that the next one will not also find.
                "options": {"expires": configured.import_maintenance_interval_seconds},
            },
            "privacy-retention-sweep": {
                "task": RETENTION_SWEEP_TASK,
                "schedule": float(configured.retention_maintenance_interval_seconds),
                "options": {
                    "expires": configured.retention_maintenance_interval_seconds
                },
            },
        },
    )
    return application


celery_app = create_celery_app()
worker_tracer_provider = instrument_worker(Settings())
