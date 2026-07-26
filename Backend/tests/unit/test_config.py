from datetime import UTC

import pytest
from pydantic import SecretStr, ValidationError

from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.clock import SystemClock
from ladle.config import Settings

GOOD_SECRET = "production-only-test-secret-that-is-at-least-32-bytes"
PRODUCTION_ATTEST = {
    "attestation_enforced": True,
    "app_attest_app_id_prefix": "ABCDE12345",
    "app_attest_bundle_id": "com.ladle.ios",
    "rate_limiting_enabled": True,
}


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
    values: dict[str, object] = {
        "environment": "production",
        "_env_file": None,
        **PRODUCTION_ATTEST,
    }
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
        **PRODUCTION_ATTEST,
        _env_file=None,
    )

    assert settings.supadata_api_key is None
    assert settings.soscripted_api_key is None
    assert settings.anthropic_api_key is None


def test_live_worker_requires_only_its_extraction_provider_key() -> None:
    settings = Settings(
        environment="production",
        jwt_signing_secret=GOOD_SECRET,
        data_encryption_key=GOOD_SECRET,
        worker_provider_mode="live",
        openrouter_api_key="openrouter-secret",
        **PRODUCTION_ATTEST,
        _env_file=None,
    )

    assert settings.supadata_api_key is None
    assert settings.soscripted_api_key is None


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


def test_soscripted_default_allows_its_synchronous_transcription_window() -> None:
    settings = Settings(_env_file=None)

    assert settings.soscripted_timeout_seconds == 600


def test_production_requires_app_attest_and_its_identity() -> None:
    with pytest.raises(ValidationError):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            _env_file=None,
        )

    settings = Settings(
        environment="production",
        jwt_signing_secret=GOOD_SECRET,
        data_encryption_key=GOOD_SECRET,
        attestation_enforced=True,
        app_attest_app_id_prefix="ABCDE12345",
        app_attest_bundle_id="com.ladle.ios",
        rate_limiting_enabled=True,
        _env_file=None,
    )

    assert settings.app_attest_app_id == "ABCDE12345.com.ladle.ios"

    with pytest.raises(RuntimeError, match="App Attest verifier"):
        create_app(
            settings=settings,
            attestation=AttestationService(enforced=True, verifier=None),
        )


def test_production_requires_distributed_rate_limiting() -> None:
    with pytest.raises(ValidationError, match="rate limiting"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            attestation_enforced=True,
            app_attest_app_id_prefix="ABCDE12345",
            app_attest_bundle_id="com.ladle.ios",
            rate_limiting_enabled=False,
            _env_file=None,
        )


def test_enabled_google_sign_in_requires_server_client_id() -> None:
    with pytest.raises(ValidationError, match="Google sign-in"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            google_enabled=True,
            **PRODUCTION_ATTEST,
            _env_file=None,
        )


def test_system_clock_returns_timezone_aware_utc() -> None:
    value = SystemClock().now()

    assert value.tzinfo is UTC
    assert value.utcoffset() is not None


@pytest.mark.parametrize(
    "override",
    [
        {"extraction_claim_minutes": 1, "extraction_claim_heartbeat_seconds": 30},
        {
            "celery_task_soft_time_limit_seconds": 600,
            "soscripted_timeout_seconds": 600,
        },
        {
            "celery_task_soft_time_limit_seconds": 1200,
            "celery_task_time_limit_seconds": 1200,
        },
        {
            "celery_task_time_limit_seconds": 1800,
            "celery_visibility_timeout_seconds": 1800,
        },
        {
            "celery_visibility_timeout_seconds": 3600,
            "import_stale_after_minutes": 60,
        },
        {
            "import_stale_after_minutes": 60,
            "import_reservation_minutes": 60,
        },
        {
            "celery_task_time_limit_seconds": 1800,
            "provider_budget_reservation_minutes": 30,
        },
    ],
)
def test_cross_setting_timing_constraints_fail_closed(
    override: dict[str, object],
) -> None:
    with pytest.raises(ValidationError, match="timing"):
        Settings(**override, _env_file=None)


def test_default_worker_timing_chain_is_safe() -> None:
    settings = Settings(_env_file=None)

    assert (
        settings.extraction_claim_heartbeat_seconds * 2
        < settings.extraction_claim_minutes * 60
    )
    assert (
        settings.soscripted_timeout_seconds
        < settings.celery_task_soft_time_limit_seconds
        < settings.celery_task_time_limit_seconds
        < settings.celery_visibility_timeout_seconds
        < settings.import_stale_after_minutes * 60
        < settings.import_reservation_minutes * 60
    )
    assert (
        settings.celery_task_time_limit_seconds
        < settings.provider_budget_reservation_minutes * 60
    )
