from dataclasses import dataclass

import pytest
from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.api.routes.ops import OPS_COOKIE
from ladle.config import Settings

TOKEN = "ops-dashboard-secret-that-is-long-enough"


@dataclass
class Probe:
    healthy: bool
    calls: int = 0

    def check(self) -> None:
        self.calls += 1
        if not self.healthy:
            raise RuntimeError("dependency unavailable")


def _client(**overrides: object) -> TestClient:
    app = create_app(
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None, **overrides),
        readiness_probes={"database": Probe(healthy=True)},
    )
    return TestClient(app)


def test_dashboard_and_its_data_are_hidden_without_the_token() -> None:
    with _client() as client:
        assert client.get("/ops").status_code == 404
        assert client.get("/ops", params={"token": "wrong"}).status_code == 404
        assert client.get("/ops/metrics.json").status_code == 404
        assert client.get("/ops/readiness.json").status_code == 404


def test_token_in_the_query_moves_into_a_cookie_and_leaves_the_url() -> None:
    with _client() as client:
        handoff = client.get("/ops", params={"token": TOKEN}, follow_redirects=False)

        assert handoff.status_code == 303
        assert handoff.headers["location"] == "/ops"
        cookie = handoff.headers["set-cookie"]
        assert "HttpOnly" in cookie
        assert "SameSite=strict" in cookie.replace("samesite", "SameSite")
        assert TOKEN not in handoff.headers["location"]

        page = client.get("/ops")

    assert page.status_code == 200
    assert page.headers["content-type"].startswith("text/html")


def test_dashboard_credential_is_not_the_prometheus_token() -> None:
    settings = Settings(
        ops_dashboard_token=TOKEN,
        metrics_auth_token="metrics-secret-that-is-long-enough",
        _env_file=None,
    )
    app = create_app(settings=settings, readiness_probes={"database": Probe(True)})

    with TestClient(app) as client:
        client.cookies.set(OPS_COOKIE, "metrics-secret-that-is-long-enough")
        assert client.get("/ops").status_code == 404


def test_metrics_json_reports_served_requests_without_a_readiness_check() -> None:
    probe = Probe(healthy=True)
    app = create_app(
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None),
        readiness_probes={"database": probe},
    )

    with TestClient(app) as client:
        client.get("/ops", params={"token": TOKEN})
        client.get("/health/live")
        before = probe.calls
        payload = client.get("/ops/metrics.json").json()

    assert probe.calls == before, "the fast poll must not wake dependency probes"
    assert payload["generatedAt"]
    served = [
        entry
        for entry in payload["series"]
        if entry["name"] == "ladle_http_requests_total"
        and entry["labels"]["route"] == "/health/live"
    ]
    assert served == [
        {
            "name": "ladle_http_requests_total",
            "labels": {"method": "GET", "route": "/health/live", "status": "2xx"},
            "value": 1,
        }
    ]


def test_readiness_json_is_a_separate_slower_endpoint() -> None:
    probe = Probe(healthy=False)
    app = create_app(
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None),
        readiness_probes={"database": probe},
    )

    with TestClient(app) as client:
        client.get("/ops", params={"token": TOKEN})
        payload = client.get("/ops/readiness.json").json()

    assert payload == {"healthy": False, "checks": {"database": "unavailable"}}


def test_dashboard_page_may_run_its_own_inline_script_and_styles() -> None:
    with _client() as client:
        client.get("/ops", params={"token": TOKEN})
        page = client.get("/ops")
        elsewhere = client.get("/health/live")

    policy = page.headers["content-security-policy"]
    assert "script-src 'self' 'unsafe-inline'" in policy
    assert "style-src 'self' 'unsafe-inline'" in policy
    assert "connect-src 'self'" in policy
    assert "frame-ancestors 'none'" in policy
    assert elsewhere.headers["content-security-policy"] == (
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    )


def test_production_refuses_to_start_without_a_dashboard_token() -> None:
    with pytest.raises(ValueError, match="dashboard"):
        Settings(
            environment="production",
            ops_dashboard_token=None,
            _env_file=None,
        )


def test_the_cookie_is_secure_whenever_the_request_arrived_over_https() -> None:
    # The VPS runs LADLE_ENVIRONMENT=development behind an HTTPS gateway, so
    # the flag has to follow the scheme Caddy forwarded, not the environment.
    app = create_app(
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None),
        readiness_probes={"database": Probe(healthy=True)},
    )

    with TestClient(app, base_url="https://ladle.example.test") as client:
        secure = client.get("/ops", params={"token": TOKEN}, follow_redirects=False)
    with TestClient(app, base_url="http://ladle.localhost") as client:
        plain = client.get("/ops", params={"token": TOKEN}, follow_redirects=False)

    assert "Secure" in secure.headers["set-cookie"]
    # Local development is served over plain HTTP; a Secure cookie there would
    # be dropped by the browser and the dashboard would never open.
    assert "Secure" not in plain.headers["set-cookie"]


def _handoff(client_address: tuple[str, int], headers: dict[str, str]) -> str:
    app = create_app(
        settings=Settings(
            ops_dashboard_token=TOKEN,
            rate_limit_trusted_proxy_cidrs="172.30.0.0/24",
            _env_file=None,
        ),
        readiness_probes={"database": Probe(healthy=True)},
    )
    with TestClient(app, client=client_address) as client:
        response = client.get(
            "/ops",
            params={"token": TOKEN},
            headers=headers,
            follow_redirects=False,
        )
    return response.headers["set-cookie"]


def test_a_trusted_gateway_reporting_https_gets_a_secure_cookie() -> None:
    # Uvicorn runs with --proxy-headers but trusts only the loopback, so the
    # forwarded scheme has to be read with the same trust list the rate
    # limiter already uses for X-Forwarded-For.
    assert "Secure" in _handoff(("172.30.0.3", 51000), {"x-forwarded-proto": "https"})


def test_an_untrusted_peer_cannot_talk_its_way_into_a_secure_cookie() -> None:
    assert "Secure" not in _handoff(
        ("203.0.113.9", 51000), {"x-forwarded-proto": "https"}
    )


def test_plain_local_http_still_gets_a_cookie_the_browser_will_store() -> None:
    assert "Secure" not in _handoff(("127.0.0.1", 51000), {})
