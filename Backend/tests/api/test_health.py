from dataclasses import dataclass

from fastapi.testclient import TestClient

from ladle.api.app import create_app


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
