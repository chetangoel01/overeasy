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
PRODUCTION_RUNTIME = {
    **PRODUCTION_ATTEST,
    "celery_enabled": True,
    "celery_broker_url": (
        "rediss://:production-redis-password@redis.example.test:6380/0"
    ),
    "celery_result_backend": (
        "rediss://:production-redis-password@redis.example.test:6380/1"
    ),
    "rate_limit_redis_url": (
        "rediss://:production-redis-password@redis.example.test:6380/2"
    ),
    "worker_provider_mode": "live",
    "openrouter_api_key": "production-openrouter-key",
    "database_url": (
        "postgresql+psycopg://ladle:production-database-password"
        "@database.example.test/ladle"
        "?sslmode=require"
    ),
    "object_storage_enabled": True,
    "object_storage_endpoint_url": "https://objects.example.test",
    "object_storage_access_key": "production-access-key",
    "object_storage_secret_key": GOOD_SECRET,
    "data_encryption_active_key_id": "2026-q3",
    "data_encryption_keyring": (
        '{"2026-q2":"production-encryption-key-material-previous",'
        '"2026-q3":"production-encryption-key-material-current"}'
    ),
    "metrics_redis_url": (
        "rediss://:production-redis-password@redis.example.test:6380/3"
    ),
    "durable_metrics_enabled": True,
    "metrics_auth_token": GOOD_SECRET,
    "tracing_enabled": True,
    "tracing_otlp_endpoint": "https://telemetry.example.test/v1/traces",
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
        **PRODUCTION_RUNTIME,
    }
    if signing_secret is not None:
        values["jwt_signing_secret"] = signing_secret
    if encryption_key is not None:
        values["data_encryption_key"] = encryption_key

    with pytest.raises(ValidationError):
        Settings(**values)


@pytest.mark.parametrize(
    ("active_key_id", "keyring"),
    [
        (None, None),
        ("missing", '{"current":"production-encryption-key-material-current"}'),
        ("current", '{"current":"too-short"}'),
        ("current", '{"current":"change-me-production-key-material"}'),
        ("bad key id", '{"bad key id":"production-encryption-key-material-current"}'),
    ],
)
def test_production_requires_valid_managed_encryption_keyring(
    active_key_id: str | None,
    keyring: str | None,
) -> None:
    values = {
        **PRODUCTION_RUNTIME,
        "data_encryption_active_key_id": active_key_id,
        "data_encryption_keyring": keyring,
    }

    with pytest.raises(ValidationError, match="encryption"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            **values,
            _env_file=None,
        )


def test_production_allows_unconfigured_optional_acquisition_providers() -> None:
    settings = Settings(
        environment="production",
        jwt_signing_secret=GOOD_SECRET,
        data_encryption_key=GOOD_SECRET,
        **PRODUCTION_RUNTIME,
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
        **PRODUCTION_RUNTIME,
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


def test_object_storage_addressing_style_loads_from_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LADLE_OBJECT_STORAGE_ADDRESSING_STYLE", "virtual")

    settings = Settings(_env_file=None)

    assert settings.object_storage_addressing_style == "virtual"


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
        **PRODUCTION_RUNTIME,
        _env_file=None,
    )

    assert settings.app_attest_app_id == "ABCDE12345.com.ladle.ios"

    with pytest.raises(RuntimeError, match="App Attest verifier"):
        create_app(
            settings=settings,
            attestation=AttestationService(enforced=True, verifier=None),
        )


def test_production_requires_distributed_rate_limiting() -> None:
    values = {
        **PRODUCTION_RUNTIME,
        "rate_limiting_enabled": False,
    }
    with pytest.raises(ValidationError, match="rate limiting"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            **values,
            _env_file=None,
        )


def test_enabled_google_sign_in_requires_server_client_id() -> None:
    with pytest.raises(ValidationError, match="Google sign-in"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            google_enabled=True,
            **PRODUCTION_RUNTIME,
            _env_file=None,
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("celery_enabled", False),
        ("worker_provider_mode", "fake"),
        ("celery_broker_url", "redis://redis.example.test:6379/0"),
        ("celery_result_backend", "redis://redis.example.test:6379/1"),
        ("rate_limit_redis_url", "redis://redis.example.test:6379/2"),
        ("metrics_redis_url", "redis://redis.example.test:6379/3"),
        ("metrics_auth_token", None),
        ("tracing_enabled", False),
        ("tracing_otlp_endpoint", "http://telemetry.example.test/v1/traces"),
        (
            "database_url",
            "postgresql+psycopg://ladle:secret@database.example.test/ladle",
        ),
        ("object_storage_enabled", False),
        ("object_storage_endpoint_url", "http://objects.example.test"),
        ("object_storage_access_key", "ladle-local"),
        ("object_storage_secret_key", "ladle-local-secret"),
        ("openrouter_api_key", None),
        ("openrouter_base_url", "http://openrouter.example.test/api/v1"),
    ],
)
def test_production_runtime_dependencies_fail_closed(
    field: str,
    value: object,
) -> None:
    values = {
        **PRODUCTION_RUNTIME,
        field: value,
    }

    with pytest.raises(ValidationError, match="production"):
        Settings(
            environment="production",
            jwt_signing_secret=GOOD_SECRET,
            data_encryption_key=GOOD_SECRET,
            **values,
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
