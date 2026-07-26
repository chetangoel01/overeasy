from ladle.config import Settings
from ladle.imports.maintenance import RELEASE_EXPIRED_RESERVATIONS_TASK
from ladle.worker.app import celery_app, create_celery_app


def test_worker_uses_late_ack_and_long_visibility_timeout() -> None:
    app = create_celery_app(
        Settings(
            celery_broker_url="redis://127.0.0.1:6379/0",
            celery_result_backend="redis://127.0.0.1:6379/1",
            celery_visibility_timeout_seconds=1800,
            celery_task_soft_time_limit_seconds=1200,
            celery_task_time_limit_seconds=1260,
        )
    )

    assert app.conf.task_acks_late is True
    assert app.conf.task_reject_on_worker_lost is True
    assert app.conf.broker_transport_options["visibility_timeout"] == 1800
    assert app.conf.task_soft_time_limit == 1200
    assert app.conf.task_time_limit == 1260
    assert app.conf.worker_prefetch_multiplier == 1
    assert app.conf.broker_connection_retry_on_startup is True
    assert app.conf.task_serializer == "json"
    assert app.conf.accept_content == ["json"]


def test_abandoned_imports_are_swept_on_a_schedule() -> None:
    """The sweep only reclaims stranded jobs if something actually runs it."""

    app = create_celery_app(Settings(import_maintenance_interval_seconds=120))

    entry = app.conf.beat_schedule["release-expired-reservations"]
    assert entry["task"] == RELEASE_EXPIRED_RESERVATIONS_TASK
    assert entry["schedule"] == 120.0
    # A backlog of sweeps is redundant: the next one sees everything the
    # expired ones would have.
    assert entry["options"]["expires"] == 120


def test_sweep_task_is_registered_on_the_worker() -> None:
    # Imported for its registration side effect, which is the thing at risk:
    # a scheduled task the worker never registered is silently never run.
    import ladle.worker.tasks  # noqa: F401

    assert RELEASE_EXPIRED_RESERVATIONS_TASK in celery_app.tasks
