from ladle.config import Settings
from ladle.worker.app import create_celery_app


def test_worker_uses_late_ack_and_long_visibility_timeout() -> None:
    app = create_celery_app(
        Settings(
            celery_broker_url="redis://127.0.0.1:6379/0",
            celery_result_backend="redis://127.0.0.1:6379/1",
            celery_visibility_timeout_seconds=3600,
        )
    )

    assert app.conf.task_acks_late is True
    assert app.conf.task_reject_on_worker_lost is True
    assert app.conf.broker_transport_options["visibility_timeout"] == 3600
    assert app.conf.task_serializer == "json"
    assert app.conf.accept_content == ["json"]
