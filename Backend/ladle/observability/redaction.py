import re
from collections.abc import Mapping

from pydantic import SecretStr

_REDACTED = "[REDACTED]"
_SENSITIVE_KEYS = frozenset(
    {
        "accesstoken",
        "apikey",
        "anthropicapikey",
        "authorization",
        "clientsecret",
        "cookie",
        "correctionnotes",
        "dataencryptionkey",
        "dataencryptionkeyring",
        "idtoken",
        "identitytoken",
        "jwtsigningsecret",
        "metricsauthtoken",
        "openrouterapikey",
        "appleprivatekey",
        "password",
        "pastedtext",
        "proxyauthorization",
        "providerkey",
        "refreshtoken",
        "setcookie",
        "soscriptedapikey",
        "supadataapikey",
        "xapikey",
    }
)
_BEARER_CREDENTIAL = re.compile(
    r"\bBearer\s+[A-Za-z0-9._~+/\-=]{8,}",
    flags=re.IGNORECASE,
)


def _normalize_key(key: object) -> str:
    return "".join(
        character for character in str(key).casefold() if character.isalnum()
    )


def _redact_value(value: object) -> object:
    if isinstance(value, SecretStr):
        return _REDACTED
    if isinstance(value, Mapping):
        return {
            key: _REDACTED
            if _normalize_key(key) in _SENSITIVE_KEYS
            else _redact_value(nested)
            for key, nested in value.items()
        }
    if isinstance(value, list):
        return [_redact_value(item) for item in value]
    if isinstance(value, tuple):
        return tuple(_redact_value(item) for item in value)
    if isinstance(value, str):
        return _BEARER_CREDENTIAL.sub(_REDACTED, value)
    return value


def redact_event(event: Mapping[str, object]) -> dict[str, object]:
    """Return a redacted copy of a structured event."""

    return {
        key: _REDACTED
        if _normalize_key(key) in _SENSITIVE_KEYS
        else _redact_value(value)
        for key, value in event.items()
    }
