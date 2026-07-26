from uuid import UUID

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from ladle.api.app import create_app
from ladle.api.rate_limits import RateLimitBackend


class RejectingRateLimitBackend(RateLimitBackend):
    def retry_after(self, _checks: object) -> int | None:
        return 17


def assert_error(
    response_status: int,
    payload: dict[str, object],
    *,
    code: str,
) -> UUID:
    assert response_status >= 400
    assert set(payload) == {"error"}
    error = payload["error"]
    assert isinstance(error, dict)
    assert error["code"] == code
    assert isinstance(error["message"], str)
    assert isinstance(error["retryable"], bool)
    assert error["details"] is None
    return UUID(str(error["requestID"]))


def test_http_and_validation_errors_use_contract_envelope_and_request_id() -> None:
    app = create_app()
    requested_id = UUID("12345678-1234-4234-8234-123456789abc")

    with TestClient(app) as client:
        unauthorized = client.get(
            "/v1/recipes/sync",
            headers={"X-Request-ID": str(requested_id)},
        )
        validation = client.post("/v1/auth/guest", json={})
        missing = client.get("/v1/does-not-exist")

    assert (
        assert_error(
            unauthorized.status_code,
            unauthorized.json(),
            code="authenticationRequired",
        )
        == requested_id
    )
    assert unauthorized.headers["X-Request-ID"] == str(requested_id)
    assert_error(validation.status_code, validation.json(), code="invalidRequest")
    assert_error(missing.status_code, missing.json(), code="notFound")


def test_unhandled_errors_are_redacted_and_use_internal_envelope(
    caplog: pytest.LogCaptureFixture,
) -> None:
    app: FastAPI = create_app()

    @app.get("/explode")
    def explode() -> None:
        raise RuntimeError("private pasted text must not be logged")

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get(
            "/explode",
            headers={"Authorization": "Bearer top-secret-token-value"},
        )

    assert_error(response.status_code, response.json(), code="internalError")
    assert "top-secret-token-value" not in caplog.text
    assert "private pasted text" not in caplog.text


def test_rate_limit_returns_typed_429_and_retry_after() -> None:
    app = create_app(rate_limit_backend=RejectingRateLimitBackend())

    with TestClient(app) as client:
        response = client.get("/v1/recipes/sync")

    assert response.status_code == 429
    assert response.headers["Retry-After"] == "17"
    error = response.json()["error"]
    assert error["code"] == "rateLimited"
    assert error["retryable"] is True
    assert error["details"]["retryAt"] is not None
