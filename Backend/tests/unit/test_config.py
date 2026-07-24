from datetime import UTC

import pytest
from pydantic import SecretStr, ValidationError

from ladle.clock import SystemClock
from ladle.config import Settings

GOOD_SECRET = "production-only-test-secret-that-is-at-least-32-bytes"


@pytest.mark.parametrize(
    ("signing_secret", "encryption_key"),
    [
        (None, None),
        ("", GOOD_SECRET),
        (GOOD_SECRET, ""),
        ("change-me", GOOD_SECRET),
        (GOOD_SECRET, "change-me"),
        ("too-short", GOOD_SECRET),
        (GOOD_SECRET, "too-short"),
    ],
)
def test_production_rejects_missing_placeholder_or_short_core_secrets(
    signing_secret: str | None,
    encryption_key: str | None,
) -> None:
    values: dict[str, object] = {"environment": "production", "_env_file": None}
    if signing_secret is not None:
        values["jwt_signing_secret"] = signing_secret
    if encryption_key is not None:
        values["data_encryption_key"] = encryption_key

    with pytest.raises(ValidationError):
        Settings(**values)


def test_production_allows_unconfigured_optional_providers() -> None:
    settings = Settings(
        environment="production",
        jwt_signing_secret=GOOD_SECRET,
        data_encryption_key=GOOD_SECRET,
        _env_file=None,
    )

    assert settings.supadata_api_key is None
    assert settings.soscripted_api_key is None
    assert settings.anthropic_api_key is None


def test_empty_provider_environment_values_are_unconfigured(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LADLE_SUPADATA_API_KEY", "")
    monkeypatch.setenv("LADLE_SOSCRIPTED_API_KEY", "")
    monkeypatch.setenv("LADLE_ANTHROPIC_API_KEY", "")

    settings = Settings(_env_file=None)

    assert settings.supadata_api_key is None
    assert settings.soscripted_api_key is None
    assert settings.anthropic_api_key is None


def test_settings_load_prefixed_provider_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LADLE_SUPADATA_BASE_URL", "https://captions.example.test/v1")
    monkeypatch.setenv("LADLE_SUPADATA_TIMEOUT_SECONDS", "12.5")
    monkeypatch.setenv("LADLE_SUPADATA_API_KEY", "provider-secret")

    settings = Settings(_env_file=None)

    assert str(settings.supadata_base_url) == "https://captions.example.test/v1"
    assert settings.supadata_timeout_seconds == 12.5
    assert settings.supadata_api_key == SecretStr("provider-secret")
    assert "provider-secret" not in repr(settings)


def test_system_clock_returns_timezone_aware_utc() -> None:
    value = SystemClock().now()

    assert value.tzinfo is UTC
    assert value.utcoffset() is not None
