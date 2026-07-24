from copy import deepcopy

from pydantic import SecretStr

from ladle.observability.redaction import redact_event


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
