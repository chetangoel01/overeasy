import json

from ladle.observability.recent import MemoryRecentBackend, RecentRequests


def _entry(route: str, status: int = 200) -> dict[str, object]:
    return {
        "at": "2026-09-04T18:00:00+00:00",
        "request_id": "abc",
        "method": "GET",
        "route": route,
        "status_code": status,
        "duration_ms": 12.5,
    }


def test_the_newest_request_comes_back_first() -> None:
    recent = RecentRequests(backend=MemoryRecentBackend(), limit=10)
    recent.record(_entry("/v1/recipes"))
    recent.record(_entry("/v1/sync"))

    assert [e["route"] for e in recent.snapshot()] == ["/v1/sync", "/v1/recipes"]


def test_it_keeps_only_the_configured_number() -> None:
    recent = RecentRequests(backend=MemoryRecentBackend(), limit=3)
    for index in range(10):
        recent.record(_entry(f"/v1/r{index}"))

    kept = recent.snapshot()
    assert len(kept) == 3
    assert [e["route"] for e in kept] == ["/v1/r9", "/v1/r8", "/v1/r7"]


def test_it_refuses_to_store_anything_but_the_agreed_fields() -> None:
    # The whole point is that no body, path parameter or header reaches it.
    recent = RecentRequests(backend=MemoryRecentBackend(), limit=5)
    recent.record({**_entry("/v1/recipes"), "body": "1 cup flour", "token": "secret"})

    stored = recent.snapshot()[0]
    assert "body" not in stored
    assert "token" not in stored
    assert set(stored) <= {
        "at",
        "request_id",
        "method",
        "route",
        "status_code",
        "duration_ms",
        "user_safe_id",
    }


def test_the_recorded_route_is_the_template_not_the_requested_path() -> None:
    """The only thing keeping recipe IDs out of this list.

    A string check cannot tell `/v1/recipes/discover` from
    `/v1/recipes/<an id>`, so the guarantee has to live at the call site: the
    middleware records Starlette's matched route template. This pins it.
    """

    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from ladle.observability.metrics import MetricsRegistry
    from ladle.observability.middleware import install_request_middleware

    recorded = RecentRequests(backend=MemoryRecentBackend(), limit=5)
    app = FastAPI()

    @app.get("/v1/recipes/{recipe_id}")
    def read(recipe_id: str) -> dict[str, str]:
        return {"id": recipe_id}

    install_request_middleware(app, metrics=MetricsRegistry(), recent=recorded)
    with TestClient(app) as client:
        client.get("/v1/recipes/7f3a-secret-looking-identifier")

    entry = recorded.snapshot()[0]
    assert entry["route"] == "/v1/recipes/{recipe_id}"
    assert "7f3a" not in json.dumps(entry)
