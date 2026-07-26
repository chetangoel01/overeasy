from fastapi.testclient import TestClient

from ladle.api.app import create_app
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
