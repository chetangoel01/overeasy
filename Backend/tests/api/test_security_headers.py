from collections.abc import Sequence

import httpx
from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.api.rate_limits import RateLimitBackend, RateLimitCheck
from ladle.config import Settings


def test_api_responses_set_browser_security_and_cache_headers() -> None:
    app = create_app(settings=Settings(environment="test", _env_file=None))

    with TestClient(app) as client:
        response = client.get("/health/live")

    assert response.status_code == 200
    assert response.headers["X-Content-Type-Options"] == "nosniff"
    assert response.headers["X-Frame-Options"] == "DENY"
    assert response.headers["Referrer-Policy"] == "no-referrer"
    assert response.headers["Cache-Control"] == "no-store"
    assert response.headers["Content-Security-Policy"] == (
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    )
    assert response.headers["Permissions-Policy"] == (
        "camera=(), geolocation=(), microphone=()"
    )
    assert "Strict-Transport-Security" not in response.headers


def test_production_security_headers_include_hsts() -> None:
    from ladle.api.security_headers import SecurityHeadersMiddleware

    assert (
        SecurityHeadersMiddleware.headers(production=True)["Strict-Transport-Security"]
        == "max-age=63072000; includeSubDomains; preload"
    )


class BlockedRateLimitBackend(RateLimitBackend):
    """Rejects every check, so any request observes the global 429 path."""

    def retry_after(self, checks: Sequence[RateLimitCheck]) -> int | None:
        del checks
        return 30


def assert_security_headers(response: httpx.Response) -> None:
    from ladle.api.security_headers import SecurityHeadersMiddleware

    for name, value in SecurityHeadersMiddleware.headers(production=False).items():
        assert response.headers.get(name) == value, name


def test_globally_rate_limited_responses_carry_the_security_headers() -> None:
    """The 429 short-circuits in middleware, before any route runs.

    It must still carry every mandatory header — an intermediary is
    otherwise free to cache a response the design marks no-store.
    """
    app = create_app(
        settings=Settings(environment="test", _env_file=None),
        rate_limit_backend=BlockedRateLimitBackend(),
    )

    with TestClient(app) as client:
        response = client.get("/health/live")

    assert response.status_code == 429
    assert response.headers["Retry-After"] == "30"
    assert_security_headers(response)


def test_unhandled_exception_responses_carry_the_security_headers() -> None:
    """The catch-all 500 is served from outside the middleware stack."""
    app = create_app(settings=Settings(environment="test", _env_file=None))

    @app.get("/boom")
    def boom() -> None:
        raise RuntimeError("boom")

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/boom")

    assert response.status_code == 500
    assert_security_headers(response)
