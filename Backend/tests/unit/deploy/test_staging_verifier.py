import httpx
import pytest

from scripts.verify_staging import VerificationFailed, verify

SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "Content-Security-Policy": (
        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    ),
    "Permissions-Policy": "camera=(), geolocation=(), microphone=()",
    "Referrer-Policy": "no-referrer",
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains; preload",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}


def test_staging_verifier_checks_public_security_boundary() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/health/live":
            return httpx.Response(
                200,
                json={"status": "live"},
                headers=SECURITY_HEADERS,
            )
        if request.url.path == "/health/ready":
            return httpx.Response(200, json={"status": "ready", "checks": {}})
        if request.url.path in {"/openapi.json", "/docs", "/redoc", "/metrics"}:
            return httpx.Response(404)
        if request.url.path == "/v1/recipes/sync":
            return httpx.Response(
                401,
                json={"error": {"code": "authenticationRequired"}},
            )
        if request.url.path == "/v1/auth/guest":
            return httpx.Response(
                413,
                json={"error": {"code": "invalidRequest"}},
            )
        raise AssertionError(request.url)

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        result = verify(base_url="https://staging.example", client=client)

    assert set(result.checks) == {
        "TLS",
        "authentication",
        "dependencies",
        "exposedEndpoints",
        "requestTooLarge",
        "secretLeakage",
        "securityHeaders",
    }


def test_staging_verifier_refuses_cleartext_target() -> None:
    with httpx.Client() as client, pytest.raises(VerificationFailed, match="HTTPS"):
        verify(base_url="http://staging.example", client=client)
