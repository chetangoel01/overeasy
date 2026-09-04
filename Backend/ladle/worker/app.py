import logging
from pathlib import Path

from celery import Celery
from celery.signals import heartbeat_sent, setup_logging, worker_ready

from ladle.clock import Clock, SystemClock
from ladle.config import Settings
from ladle.imports.dispatcher import PROCESS_IMPORT_TASK
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.observability.metrics import MetricsRegistry
from ladle.observability.structured_logging import configure_structured_logging
from ladle.observability.tracing import instrument_worker
from ladle.privacy.retention import RETENTION_SWEEP_TASK

LOGGER = logging.getLogger("ladle.worker")


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
        task_default_delivery_mode="persistent",
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


def configure_worker_logging(
    *,
    settings: Settings | None = None,
    **_: object,
) -> None:
    configured = settings or _worker_settings
    if configured.structured_logging_enabled:
        configure_structured_logging(level=configured.log_level)


# Written on every Celery heartbeat so a container health check can learn the
# worker is alive by stat-ing a file, instead of spending eleven seconds and a
# whole Python interpreter on `celery inspect ping`. /tmp is tmpfs in the
# deployment, which is why this works under read_only: true.
WORKER_BEACON = Path("/tmp/worker-heartbeat")


def record_worker_heartbeat(
    *,
    metrics: MetricsRegistry | None = None,
    clock: Clock | None = None,
    beacon: Path | None = None,
    **_: object,
) -> None:
    if metrics is None:
        from ladle.worker.runtime import runtime_metrics

        metrics = runtime_metrics()
    metrics.set_operational(
        "ladle_worker_last_seen_timestamp_seconds",
        (clock or SystemClock()).now().timestamp(),
    )
    try:
        (beacon or WORKER_BEACON).touch()
    except OSError:
        # Liveness bookkeeping must never be able to kill the process it
        # reports on. A missing beacon just makes the probe go stale, which is
        # the honest outcome anyway.
        LOGGER.warning("could not write the worker heartbeat beacon")


_worker_settings = Settings()
celery_app = create_celery_app(_worker_settings)
# Follows the setting, not the environment. The deployed host runs the
# documented LADLE_ENVIRONMENT=development exception, so gating on
# "production" here meant worker output never reached the redacting formatter
# on the one machine where that mattered. configure_worker_logging checks the
# setting again, so connecting unconditionally stays correct when it is off.
setup_logging.connect(configure_worker_logging, weak=False)
heartbeat_sent.connect(record_worker_heartbeat, weak=False)
worker_ready.connect(record_worker_heartbeat, weak=False)
worker_tracer_provider = instrument_worker(_worker_settings)
