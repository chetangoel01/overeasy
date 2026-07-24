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

    supadata_base_url: AnyHttpUrl = AnyHttpUrl("https://api.supadata.ai/v1")
    supadata_timeout_seconds: float = Field(default=30, gt=0)
    supadata_api_key: SecretStr | None = None

    soscripted_base_url: AnyHttpUrl = AnyHttpUrl("https://api.soscripted.com")
    soscripted_timeout_seconds: float = Field(default=30, gt=0)
    soscripted_api_key: SecretStr | None = None

    anthropic_base_url: AnyHttpUrl = AnyHttpUrl("https://api.anthropic.com")
    anthropic_timeout_seconds: float = Field(default=60, gt=0)
    anthropic_api_key: SecretStr | None = None

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
        return self
