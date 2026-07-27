"""Run non-destructive external security checks against a staging deployment."""

import argparse
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import httpx


class VerificationFailed(RuntimeError):
    pass


@dataclass(frozen=True)
class VerificationResult:
    checks: tuple[str, ...]


_SECURITY_HEADERS = {
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


def verify(
    *,
    base_url: str,
    client: httpx.Client,
    maximum_body_bytes: int = 1024 * 1024,
    exercise_rate_limit: bool = False,
    access_token: str | None = None,
    attestation_headers: Mapping[str, str] | None = None,
    attested_request_body: bytes | None = None,
) -> VerificationResult:
    if urlsplit(base_url).scheme != "https":
        raise VerificationFailed("staging URL must use HTTPS")
    checks: list[str] = []

    live = client.get(f"{base_url}/health/live")
    _status(live, 200, "liveness")
    if live.json() != {"status": "live"}:
        raise VerificationFailed("liveness response is unexpected")
    for name, expected in _SECURITY_HEADERS.items():
        if live.headers.get(name) != expected:
            raise VerificationFailed(f"{name} is missing or incorrect")
    _no_secrets(live)
    checks.extend(("TLS", "securityHeaders", "secretLeakage"))

    ready = client.get(f"{base_url}/health/ready")
    _status(ready, 200, "readiness")
    if ready.json().get("status") != "ready":
        raise VerificationFailed("readiness dependencies are not ready")
    checks.append("dependencies")

    for hidden in ("/openapi.json", "/docs", "/redoc", "/metrics"):
        _status(client.get(f"{base_url}{hidden}"), 404, hidden)
    checks.append("exposedEndpoints")

    unauthorized = client.get(f"{base_url}/v1/recipes/sync")
    _status(unauthorized, 401, "authentication")
    _error_code(unauthorized, "authenticationRequired")
    checks.append("authentication")

    oversized = client.post(
        f"{base_url}/v1/auth/guest",
        content=b"x" * (maximum_body_bytes + 1),
        headers={"Content-Type": "application/json"},
    )
    _status(oversized, 413, "requestTooLarge")
    _error_code(oversized, "invalidRequest")
    checks.append("requestTooLarge")

    if exercise_rate_limit:
        limited: httpx.Response | None = None
        body = {"installationID": f"staging-rate-{uuid4()}", "attestation": None}
        for _ in range(100):
            candidate = client.post(f"{base_url}/v1/auth/guest", json=body)
            if candidate.status_code == 429:
                limited = candidate
                break
            if candidate.status_code not in {401, 403, 422}:
                raise VerificationFailed(
                    f"rate-limit probe returned {candidate.status_code}"
                )
        if limited is None:
            raise VerificationFailed("rate limit did not produce 429")
        _error_code(limited, "rateLimited")
        if not limited.headers.get("Retry-After"):
            raise VerificationFailed("429 response has no Retry-After")
        checks.append("rateLimiting")

    attested_values = (
        access_token,
        attestation_headers,
        attested_request_body,
    )
    if any(value is not None for value in attested_values) and not all(
        value is not None for value in attested_values
    ):
        raise VerificationFailed(
            "metadata probe requires an access token, assertion headers, "
            "and exact attested request body"
        )
    if (
        access_token is not None
        and attestation_headers is not None
        and attested_request_body is not None
    ):
        _validate_metadata_body(attested_request_body)
        rejected = client.post(
            f"{base_url}/v1/imports",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                **attestation_headers,
            },
            content=attested_request_body,
        )
        if rejected.status_code not in {400, 422}:
            raise VerificationFailed("cloud metadata URL was not rejected")
        checks.append("cloudMetadataSSRF")

    return VerificationResult(checks=tuple(checks))


def _status(response: httpx.Response, expected: int, name: str) -> None:
    if response.status_code != expected:
        raise VerificationFailed(
            f"{name} returned {response.status_code}, expected {expected}"
        )


def _error_code(response: httpx.Response, expected: str) -> None:
    try:
        actual = response.json()["error"]["code"]
    except (KeyError, TypeError, ValueError) as error:
        raise VerificationFailed("typed error envelope is missing") from error
    if actual != expected:
        raise VerificationFailed(f"error code is {actual}, expected {expected}")


def _no_secrets(response: httpx.Response) -> None:
    lowered = response.text.casefold()
    for marker in ("postgresql://", "redis://", "traceback", "ladle_jwt_"):
        if marker in lowered:
            raise VerificationFailed(f"response leaked {marker}")


def _validate_metadata_body(value: bytes) -> None:
    try:
        payload = json.loads(value)
        UUID(str(payload["jobID"]))
    except (KeyError, TypeError, UnicodeDecodeError, ValueError) as error:
        raise VerificationFailed(
            "attested metadata probe body must contain a valid jobID"
        ) from error
    if (
        not isinstance(payload, dict)
        or payload.get("sourceURL") != "http://169.254.169.254/latest/meta-data"
    ):
        raise VerificationFailed(
            "attested metadata probe body must target the cloud metadata URL"
        )


def _headers(path: Path | None) -> dict[str, str] | None:
    if path is None:
        return None
    value: Any = json.loads(path.read_text())
    if not isinstance(value, dict) or not all(
        isinstance(key, str) and isinstance(item, str) for key, item in value.items()
    ):
        raise VerificationFailed("attestation header file must be a string map")
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("base_url")
    parser.add_argument("--exercise-rate-limit", action="store_true")
    parser.add_argument("--access-token")
    parser.add_argument("--attestation-headers", type=Path)
    parser.add_argument("--attested-request-body", type=Path)
    args = parser.parse_args()
    with httpx.Client(timeout=10, follow_redirects=False) as client:
        result = verify(
            base_url=args.base_url.rstrip("/"),
            client=client,
            exercise_rate_limit=args.exercise_rate_limit,
            access_token=args.access_token,
            attestation_headers=_headers(args.attestation_headers),
            attested_request_body=(
                args.attested_request_body.read_bytes()
                if args.attested_request_body is not None
                else None
            ),
        )
    print(json.dumps({"status": "passed", "checks": result.checks}))


if __name__ == "__main__":
    main()
