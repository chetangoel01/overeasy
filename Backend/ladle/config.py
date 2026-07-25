from decimal import Decimal
from typing import Literal, Self

from pydantic import AnyHttpUrl, Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_PLACEHOLDER_PREFIXES = (
    "change-me",
    "changeme",
    "development-only",
    "example",
    "placeholder",
)
_MINIMUM_PRODUCTION_SECRET_LENGTH = 32


class Settings(BaseSettings):
    """Runtime configuration loaded from explicit arguments or LADLE_* values."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_prefix="LADLE_",
        case_sensitive=False,
        extra="ignore",
        env_ignore_empty=True,
    )

    environment: Literal["development", "test", "production"] = "development"
    jwt_signing_secret: SecretStr = SecretStr("change-me-development-only")
    data_encryption_key: SecretStr = SecretStr("change-me-development-only")
    database_url: str = "postgresql+psycopg://ladle:ladle@127.0.0.1:5432/ladle"
    access_token_issuer: str = "ladle"
    access_token_minutes: int = Field(default=15, gt=0)
    refresh_token_days: int = Field(default=30, gt=0)
    refresh_rotation_grace_seconds: int = Field(default=5, ge=0)
    attestation_enforced: bool = False
    import_reservation_minutes: int = Field(default=60, gt=0)
    source_redirect_timeout_seconds: float = Field(default=10, gt=0)
    extraction_claim_minutes: int = Field(default=10, gt=0)
    public_cache_recheck_days: int = Field(default=7, gt=0)

    celery_enabled: bool = False
    celery_broker_url: str = "redis://127.0.0.1:6379/0"
    celery_result_backend: str = "redis://127.0.0.1:6379/1"
    celery_visibility_timeout_seconds: int = Field(default=3600, gt=0)
    worker_provider_mode: Literal["disabled", "fake", "live"] = "disabled"
    provider_daily_billed_unit_limit: Decimal = Field(
        default=Decimal("1000"),
        gt=0,
    )
    provider_circuit_failure_threshold: int = Field(default=3, gt=0)
    provider_circuit_cooldown_seconds: int = Field(default=300, gt=0)
    server_media_fallback_enabled: bool = False
    object_storage_enabled: bool = False
    object_storage_endpoint_url: AnyHttpUrl = AnyHttpUrl("http://127.0.0.1:9000")
    object_storage_public_endpoint_url: AnyHttpUrl | None = None
    object_storage_region: str = "us-east-1"
    object_storage_bucket: str = "ladle-private"
    object_storage_access_key: str = "ladle-local"
    object_storage_secret_key: SecretStr = SecretStr("ladle-local-secret")

    supadata_base_url: AnyHttpUrl = AnyHttpUrl("https://api.supadata.ai/v1")
    supadata_timeout_seconds: float = Field(default=30, gt=0)
    supadata_api_key: SecretStr | None = None

    soscripted_base_url: AnyHttpUrl = AnyHttpUrl("https://soscripted.com/api/public")
    soscripted_timeout_seconds: float = Field(default=30, gt=0)
    soscripted_api_key: SecretStr | None = None

    extraction_provider: Literal["anthropic", "openrouter"] = "openrouter"

    anthropic_base_url: AnyHttpUrl = AnyHttpUrl("https://api.anthropic.com")
    anthropic_timeout_seconds: float = Field(default=60, gt=0)
    anthropic_api_key: SecretStr | None = None
    anthropic_model_id: str = "claude-sonnet-4-6"
    anthropic_max_tokens: int = Field(default=8192, gt=0)

    openrouter_base_url: AnyHttpUrl = AnyHttpUrl("https://openrouter.ai/api/v1")
    openrouter_timeout_seconds: float = Field(default=90, gt=0)
    openrouter_api_key: SecretStr | None = None
    openrouter_model_id: str = "moonshotai/kimi-k2.5"
    openrouter_max_tokens: int = Field(default=8192, gt=0)

    apple_enabled: bool = False
    apple_bundle_id: str = "com.ladle.app"
    apple_team_id: str | None = None
    apple_key_id: str | None = None
    apple_private_key: SecretStr | None = None
    apple_jwks_url: AnyHttpUrl = AnyHttpUrl("https://appleid.apple.com/auth/keys")
    apple_token_url: AnyHttpUrl = AnyHttpUrl("https://appleid.apple.com/auth/token")
    apple_timeout_seconds: float = Field(default=10, gt=0)
    apple_identity_token_maximum_age_minutes: int = Field(default=10, gt=0)
    apple_clock_skew_seconds: int = Field(default=30, ge=0)

    @model_validator(mode="after")
    def normalize_blank_provider_keys(self) -> Self:
        # Compose-style `${VAR:-}` substitution surfaces unset keys as empty
        # strings; treat those as absent.
        for field_name in (
            "supadata_api_key",
            "soscripted_api_key",
            "anthropic_api_key",
            "openrouter_api_key",
        ):
            secret = getattr(self, field_name)
            if secret is not None and not secret.get_secret_value().strip():
                setattr(self, field_name, None)
        return self

    @model_validator(mode="after")
    def reject_unsafe_production_secrets(self) -> Self:
        if self.environment != "production":
            return self

        for field_name in ("jwt_signing_secret", "data_encryption_key"):
            secret = getattr(self, field_name).get_secret_value().strip()
            normalized = secret.casefold()
            if len(secret) < _MINIMUM_PRODUCTION_SECRET_LENGTH or any(
                normalized.startswith(prefix) for prefix in _PLACEHOLDER_PREFIXES
            ):
                raise ValueError(
                    f"{field_name} must be a non-placeholder secret of at least "
                    f"{_MINIMUM_PRODUCTION_SECRET_LENGTH} characters in production"
                )
        if self.object_storage_enabled:
            storage_secret = self.object_storage_secret_key.get_secret_value().strip()
            if (
                len(storage_secret) < _MINIMUM_PRODUCTION_SECRET_LENGTH
                or storage_secret.casefold().startswith(_PLACEHOLDER_PREFIXES)
            ):
                raise ValueError(
                    "object_storage_secret_key must be a non-placeholder secret "
                    "of at least 32 characters in production"
                )
        extraction_key = (
            "openrouter_api_key"
            if self.extraction_provider == "openrouter"
            else "anthropic_api_key"
        )
        if self.worker_provider_mode == "live" and any(
            getattr(self, field_name) is None
            for field_name in (
                "supadata_api_key",
                "soscripted_api_key",
                extraction_key,
            )
        ):
            raise ValueError("live production workers require configured provider keys")
        if self.apple_enabled and any(
            getattr(self, field_name) is None
            for field_name in (
                "apple_team_id",
                "apple_key_id",
                "apple_private_key",
            )
        ):
            raise ValueError(
                "Apple sign-in requires team, key, and private-key configuration"
            )
        return self
