from dataclasses import dataclass
from typing import Any

import pytest
from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.api.routes.health import (
    CeleryWorkerReadinessProbe,
    ReadinessService,
    StartupDependencyGate,
)
from ladle.config import Settings


@dataclass
class Probe:
    healthy: bool
    calls: int = 0

    def check(self) -> None:
        self.calls += 1
        if not self.healthy:
            raise RuntimeError("dependency unavailable")


def test_liveness_does_not_contact_dependencies_and_readiness_checks_all() -> None:
    database = Probe(healthy=True)
    redis = Probe(healthy=True)
    storage = Probe(healthy=True)
    app = create_app(
        readiness_probes={
            "database": database,
            "redis": redis,
            "storage": storage,
        }
    )

    with TestClient(app) as client:
        live = client.get("/health/live")
        assert live.status_code == 200
        assert live.json() == {"status": "live"}
        assert [database.calls, redis.calls, storage.calls] == [0, 0, 0]

        ready = client.get("/health/ready")

    assert ready.status_code == 200
    assert ready.json() == {
        "status": "ready",
        "checks": {
            "database": "ready",
            "redis": "ready",
            "storage": "ready",
        },
    }
    assert [database.calls, redis.calls, storage.calls] == [1, 1, 1]


def test_readiness_returns_503_when_any_dependency_is_unavailable() -> None:
    app = create_app(
        readiness_probes={
            "database": Probe(healthy=True),
            "redis": Probe(healthy=False),
            "storage": Probe(healthy=True),
        }
    )

    with TestClient(app) as client:
        response = client.get("/health/ready")

    assert response.status_code == 503
    assert response.json() == {
        "status": "notReady",
        "checks": {
            "database": "ready",
            "redis": "unavailable",
            "storage": "ready",
        },
    }


@dataclass
class Inspector:
    response: dict[str, Any] | None

    def ping(self) -> dict[str, Any] | None:
        return self.response


@dataclass
class CeleryControl:
    response: dict[str, Any] | None

    def inspect(self, *, timeout: float) -> Inspector:
        assert timeout == 2
        return Inspector(self.response)


def test_worker_readiness_requires_a_live_celery_worker() -> None:
    CeleryWorkerReadinessProbe(
        CeleryControl({"celery@worker": {"ok": "pong"}}),  # type: ignore[arg-type]
        timeout_seconds=2,
    ).check()

    with pytest.raises(RuntimeError, match="worker"):
        CeleryWorkerReadinessProbe(
            CeleryControl(None),  # type: ignore[arg-type]
            timeout_seconds=2,
        ).check()


def test_startup_gate_retries_dependencies_then_fails_closed() -> None:
    probe = Probe(healthy=False)
    sleeps: list[float] = []
    gate = StartupDependencyGate(
        ReadinessService({"database": probe}),
        attempts=3,
        delay_seconds=0.5,
        sleep=sleeps.append,
    )

    with pytest.raises(RuntimeError, match="startup dependencies"):
        gate.wait()

    assert probe.calls == 3
    assert sleeps == [0.5, 0.5]


def test_metrics_endpoint_requires_its_dedicated_bearer_token() -> None:
    app = create_app(
        settings=Settings(
            metrics_auth_token="metrics-secret-that-is-long-enough",
            _env_file=None,
        )
    )

    with TestClient(app) as client:
        hidden = client.get("/metrics")
        authorized = client.get(
            "/metrics",
            headers={"Authorization": "Bearer metrics-secret-that-is-long-enough"},
        )

    assert hidden.status_code == 404
    assert authorized.status_code == 200
    assert authorized.headers["content-type"].startswith("text/plain")
