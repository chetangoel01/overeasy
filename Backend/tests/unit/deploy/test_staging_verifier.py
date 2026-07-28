import sys
from pathlib import Path

import httpx
import pytest

from scripts import verify_staging as staging_verifier
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


def staging_response(request: httpx.Request) -> httpx.Response:
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


def test_staging_verifier_checks_public_security_boundary() -> None:
    with httpx.Client(transport=httpx.MockTransport(staging_response)) as client:
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


def test_staging_verifier_authenticates_checks_and_rejects_missing_key() -> None:
    seen: list[str | None] = []

    def respond(request: httpx.Request) -> httpx.Response:
        key = request.headers.get("X-Ladle-Tunnel-Key")
        seen.append(key)
        if key != "stage-secret":
            return httpx.Response(404)
        return staging_response(request)

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        result = verify(
            base_url="https://staging.example",
            client=client,
            staging_access_key="stage-secret",
        )

    assert "stagingAccess" in result.checks
    assert None in seen
    assert "wrong-stage-secret" in seen
    assert "stage-secret" in seen


def test_secret_rejects_an_empty_file(tmp_path: Path) -> None:
    path = tmp_path / "staging-key"
    path.write_text(" \n")

    with pytest.raises(VerificationFailed, match="empty"):
        staging_verifier._secret(path)


def test_cli_exposes_only_a_file_option_for_the_staging_key(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(sys, "argv", ["verify_staging.py", "--help"])
    with pytest.raises(SystemExit) as help_exit:
        staging_verifier.main()

    assert help_exit.value.code == 0
    assert "--staging-access-key-file" in capsys.readouterr().out

    monkeypatch.setattr(
        sys,
        "argv",
        [
            "verify_staging.py",
            "https://staging.example",
            "--staging-access-key",
            "stage-secret",
        ],
    )
    with pytest.raises(SystemExit) as key_exit:
        staging_verifier.main()

    assert key_exit.value.code == 2
    assert "--staging-access-key" in capsys.readouterr().err


def test_staging_verifier_refuses_cleartext_target() -> None:
    with httpx.Client() as client, pytest.raises(VerificationFailed, match="HTTPS"):
        verify(base_url="http://staging.example", client=client)


def test_staging_rate_limit_probe_allows_attestation_rejection_until_429() -> None:
    attempts = 0

    def respond(request: httpx.Request) -> httpx.Response:
        nonlocal attempts
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
        if request.url.path == "/v1/auth/guest" and len(request.content) > 1024:
            return httpx.Response(
                413,
                json={"error": {"code": "invalidRequest"}},
            )
        if request.url.path == "/v1/auth/guest":
            attempts += 1
            if attempts < 3:
                return httpx.Response(
                    403,
                    json={"error": {"code": "authenticationRequired"}},
                )
            return httpx.Response(
                429,
                json={"error": {"code": "rateLimited"}},
                headers={"Retry-After": "60"},
            )
        raise AssertionError(request.url)

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        result = verify(
            base_url="https://staging.example",
            client=client,
            maximum_body_bytes=1024,
            exercise_rate_limit=True,
        )

    assert "rateLimiting" in result.checks


def test_staging_ssrf_probe_sends_the_exact_pre_attested_body() -> None:
    body = (
        b'{"jobID":"12345678-1234-4234-8234-123456789abc",'
        b'"sourceURL":"http://169.254.169.254/latest/meta-data"}'
    )

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
        if request.url.path == "/v1/imports":
            assert request.content == body
            assert request.headers["X-App-Attest-Assertion"] == "signed"
            return httpx.Response(
                422,
                json={"error": {"code": "invalidURL"}},
            )
        raise AssertionError(request.url)

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        result = verify(
            base_url="https://staging.example",
            client=client,
            access_token="access",
            attestation_headers={"X-App-Attest-Assertion": "signed"},
            attested_request_body=body,
        )

    assert "cloudMetadataSSRF" in result.checks
