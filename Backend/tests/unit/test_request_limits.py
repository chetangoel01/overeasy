from collections.abc import Iterator
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from pydantic import ValidationError
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse
from starlette.routing import Route

from ladle.api.app import create_app
from ladle.api.request_limits import RequestBodyLimitMiddleware
from ladle.api.routes.imports import ImportSubmissionRequest
from ladle.auth.attestation import AttestationService
from ladle.config import Settings


async def _echo_size(request: Request) -> JSONResponse:
    return JSONResponse({"size": len(await request.body())})


def _client(*, maximum_bytes: int) -> TestClient:
    application = Starlette(routes=[Route("/", _echo_size, methods=["POST"])])
    application.add_middleware(
        RequestBodyLimitMiddleware,
        maximum_bytes=maximum_bytes,
    )
    return TestClient(application)


def test_request_body_limit_rejects_declared_oversize_before_route() -> None:
    with _client(maximum_bytes=8) as client:
        response = client.post("/", content=b"123456789")

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "invalidRequest"


def test_request_body_limit_counts_stream_when_length_is_missing() -> None:
    def chunks() -> Iterator[bytes]:
        yield b"1234"
        yield b"56789"

    with _client(maximum_bytes=8) as client:
        response = client.post(
            "/",
            content=chunks(),
            headers={"Transfer-Encoding": "chunked"},
        )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "invalidRequest"


def test_request_body_limit_replays_an_accepted_stream() -> None:
    def chunks() -> Iterator[bytes]:
        yield b"1234"
        yield b"5678"

    with _client(maximum_bytes=8) as client:
        response = client.post(
            "/",
            content=chunks(),
            headers={"Transfer-Encoding": "chunked"},
        )

    assert response.status_code == 200
    assert response.json() == {"size": 8}


def test_import_private_text_limit_is_enforced_in_utf8_bytes() -> None:
    base = {
        "jobID": str(uuid4()),
        "sourceURL": "https://youtu.be/private-text-bytes",
    }

    accepted = ImportSubmissionRequest.model_validate(
        {**base, "pastedText": "é" * 100_000}
    )
    assert accepted.pasted_text is not None
    with pytest.raises(ValidationError):
        ImportSubmissionRequest.model_validate({**base, "pastedText": "é" * 100_001})


def test_nginx_request_limit_matches_application_default() -> None:
    nginx = (
        Path(__file__).parents[2] / "deploy" / "nginx" / "request-size.conf"
    ).read_text()

    assert Settings().maximum_request_body_bytes == 1024 * 1024
    assert "client_max_body_size 1m;" in nginx


def test_api_installs_request_limit_before_request_parsing() -> None:
    application = create_app(
        attestation=AttestationService(enforced=False),
        settings=Settings(maximum_request_body_bytes=1024),
    )

    with TestClient(application) as client:
        response = client.post(
            "/v1/auth/guest",
            content=b"x" * 1025,
            headers={"Content-Type": "application/json"},
        )

    assert response.status_code == 413
    assert response.headers["X-Request-ID"] == response.json()["error"]["requestID"]
