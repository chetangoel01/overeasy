import json
import re
from dataclasses import dataclass

from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.api.routes.ops import OPS_COOKIE
from ladle.config import Settings
from ladle.observability.middleware import _POLLED

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
        # The one dashboard read that touches the database. It refuses before
        # it opens a session, so a scan costs a 404 and no query.
        assert client.get("/ops/nutrition-misses.json").status_code == 404


def test_token_in_the_query_moves_into_a_cookie_and_leaves_the_url() -> None:
    with _client() as client:
        handoff = client.get("/ops", params={"token": TOKEN}, follow_redirects=False)

        assert handoff.status_code == 303
        assert handoff.headers["location"] == "/ops"
        cookie = handoff.headers["set-cookie"]
        assert "HttpOnly" in cookie
        assert TOKEN not in handoff.headers["location"]

        # Path=/ and Lax, not Path=/ops and Strict. The dashboard hostname
        # rewrites / to /ops inside Caddy, so the browser's URL stays `/` and
        # a cookie scoped to /ops is never sent back — the bookmark 404s.
        # Strict does the same to any link opened from Slack or mail. Every
        # dashboard route is a read-only GET, so Lax gives up nothing.
        assert "Path=/;" in cookie or cookie.rstrip().endswith("Path=/")
        assert "Path=/ops" not in cookie
        assert "samesite=lax" in cookie.lower()

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


def test_every_dashboard_poll_is_excluded_from_traffic_charts() -> None:
    with _client() as client:
        client.get("/ops", params={"token": TOKEN})
        page = client.get("/ops").text

    exclusions = re.search(r"var OPS_ROUTES = (\{.*?\});", page, re.S)
    assert exclusions is not None
    routes = json.loads(exclusions.group(1))
    for poll in _POLLED:
        if poll.startswith("/ops/"):
            assert routes.get(poll) == 1, (
                f"Dashboard poll counts as user traffic: {poll}"
            )


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
    # The relaxation is the page's alone; tests/api/test_security_headers.py
    # owns what every other route sends.
    assert "unsafe-inline" not in elsewhere.headers["content-security-policy"]


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


CLIENT_CERT_HEADER = "x-ladle-ops-client"


def _certified(client_address: tuple[str, int], headers: dict[str, str]) -> int:
    app = create_app(
        settings=Settings(
            ops_dashboard_token=TOKEN,
            rate_limit_trusted_proxy_cidrs="172.30.0.0/24",
            _env_file=None,
        ),
        readiness_probes={"database": Probe(healthy=True)},
    )
    with TestClient(app, client=client_address) as client:
        return client.get("/ops", headers=headers).status_code


def test_a_verified_client_certificate_stands_in_for_the_cookie() -> None:
    # The gateway only sets this header after require_and_verify passed against
    # the dashboard's private CA, so its presence is the authorization.
    assert (
        _certified(("172.30.0.3", 51000), {CLIENT_CERT_HEADER: "CN=chetan-macbook"})
        == 200
    )


def test_an_untrusted_peer_cannot_forge_a_client_certificate() -> None:
    assert (
        _certified(("203.0.113.9", 51000), {CLIENT_CERT_HEADER: "CN=chetan-macbook"})
        == 404
    )


def test_an_empty_certificate_subject_is_not_an_identity() -> None:
    assert _certified(("172.30.0.3", 51000), {CLIENT_CERT_HEADER: ""}) == 404


def test_recent_requests_list_what_matters_and_skip_the_pollers() -> None:
    app = create_app(
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None),
        readiness_probes={"database": Probe(healthy=False)},
    )
    with TestClient(app) as client:
        client.get("/ops", params={"token": TOKEN})
        client.get("/health/live")
        client.get("/health/ready")
        listed = client.get("/ops/requests.json")

    with TestClient(app) as stranger:
        assert stranger.get("/ops/requests.json").status_code == 404

    entries = listed.json()["requests"]
    routes = [entry["route"] for entry in entries]
    # A successful probe is noise; a failing one is the first sign of trouble.
    assert "/health/live" not in routes
    assert "/health/ready" in routes
    assert "/ops/metrics.json" not in routes
    for entry in entries:
        assert set(entry) <= {
            "at",
            "request_id",
            "method",
            "route",
            "status_code",
            "duration_ms",
            "user_safe_id",
        }
