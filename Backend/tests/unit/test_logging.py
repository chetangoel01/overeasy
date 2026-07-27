import json
import logging
from copy import deepcopy
from io import StringIO
from uuid import UUID

from fastapi import FastAPI, Request
from fastapi.testclient import TestClient
from pydantic import SecretStr

from ladle.observability.metrics import MetricsRegistry
from ladle.observability.middleware import install_request_middleware
from ladle.observability.redaction import redact_event
from ladle.observability.structured_logging import (
    JSONRedactingFormatter,
    log_context,
    pseudonymous_identifier,
)


def test_sensitive_fields_are_recursively_redacted_without_mutation() -> None:
    original = {
        "Authorization": "Bearer header-secret",
        "request": {
            "correctionNotes": "less salt",
            "pasted_text": "private recipe",
            "items": [
                {"refreshToken": "refresh-secret"},
                {"safe": "keep me"},
            ],
        },
        "provider_key": SecretStr("provider-secret"),
        "x-api-key": "external-secret",
        "client_secret": "oauth-secret",
        "Proxy-Authorization": "Basic proxy-secret",
        "metadata": SecretStr("secret-object"),
    }
    untouched = deepcopy(original)

    event = redact_event(original)

    assert event == {
        "Authorization": "[REDACTED]",
        "request": {
            "correctionNotes": "[REDACTED]",
            "pasted_text": "[REDACTED]",
            "items": [
                {"refreshToken": "[REDACTED]"},
                {"safe": "keep me"},
            ],
        },
        "provider_key": "[REDACTED]",
        "x-api-key": "[REDACTED]",
        "client_secret": "[REDACTED]",
        "Proxy-Authorization": "[REDACTED]",
        "metadata": "[REDACTED]",
    }
    assert original == untouched


def test_bearer_credentials_embedded_in_text_are_redacted() -> None:
    event = redact_event(
        {
            "error": "upstream rejected Bearer abc.def-123_456",
            "padded": "upstream rejected Bearer abcdefg=",
            "safe": "Bearer is an authentication scheme",
        }
    )

    assert event["error"] == "upstream rejected [REDACTED]"
    assert event["padded"] == "upstream rejected [REDACTED]"
    assert event["safe"] == "Bearer is an authentication scheme"


def test_user_log_identifier_is_keyed_and_never_contains_the_raw_uuid() -> None:
    user_id = UUID("12345678-1234-4234-8234-123456789abc")

    first = pseudonymous_identifier(user_id, secret="environment-a-secret")
    repeated = pseudonymous_identifier(user_id, secret="environment-a-secret")
    separate_environment = pseudonymous_identifier(
        user_id,
        secret="environment-b-secret",
    )

    assert first == repeated
    assert first != separate_environment
    assert len(first) == 16
    assert str(user_id) not in first


def test_json_formatter_redacts_at_the_sink_and_adds_safe_context() -> None:
    output = StringIO()
    handler = logging.StreamHandler(output)
    handler.setFormatter(JSONRedactingFormatter())
    logger = logging.getLogger("ladle-test-json")
    logger.handlers = [handler]
    logger.propagate = False
    logger.setLevel(logging.INFO)

    with log_context(
        request_id="request-1",
        job_id="job-1",
        stage="extracting",
        provider="openrouter",
        retry_number=2,
    ):
        logger.info(
            "provider call completed",
            extra={
                "duration_ms": 120,
                "terminal_result": "ready",
                "pasted_text": "secret recipe",
                "authorization": "Bearer secret-token-value",
            },
        )

    event = json.loads(output.getvalue())
    assert event["message"] == "provider call completed"
    assert event["request_id"] == "request-1"
    assert event["job_id"] == "job-1"
    assert event["stage"] == "extracting"
    assert event["provider"] == "openrouter"
    assert event["retry_number"] == 2
    assert event["duration_ms"] == 120
    assert event["terminal_result"] == "ready"
    assert event["pasted_text"] == "[REDACTED]"
    assert event["authorization"] == "[REDACTED]"


def test_http_completion_log_includes_route_supplied_user_pseudonym(
    monkeypatch,
) -> None:
    app = FastAPI()
    events: list[dict[str, object]] = []
    monkeypatch.setattr(
        "ladle.observability.middleware.LOGGER.info",
        lambda _message, *, extra: events.append(extra),
    )

    @app.get("/authenticated")
    def authenticated(request: Request) -> dict[str, str]:
        request.state.user_safe_id = "0123456789abcdef"
        return {"status": "ok"}

    install_request_middleware(app, metrics=MetricsRegistry())

    with TestClient(app) as client:
        response = client.get("/authenticated")

    assert response.status_code == 200
    assert events[-1]["user_safe_id"] == "0123456789abcdef"
