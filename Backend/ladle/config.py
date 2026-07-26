from decimal import Decimal
from typing import Literal, Self
from urllib.parse import parse_qs, urlsplit

from pydantic import AnyHttpUrl, Field, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

_PLACEHOLDER_PREFIXES = (
    "change-me",
    "changeme",
    "development-only",
    "example",
    "ladle-local",
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
    app_attest_app_id_prefix: str | None = Field(
        default=None, min_length=10, max_length=32
    )
    app_attest_bundle_id: str | None = Field(default=None, min_length=3, max_length=255)
    app_attest_environment: Literal["development", "production"] = "production"
    app_attest_challenge_seconds: int = Field(default=300, ge=60, le=900)
    maximum_request_body_bytes: int = Field(
        default=1024 * 1024,
        ge=1024,
        le=10 * 1024 * 1024,
    )
    import_reservation_minutes: int = Field(default=60, gt=0)
    user_import_daily_quota: int = Field(default=20, gt=0)
    user_import_monthly_quota: int = Field(default=200, gt=0)
    source_redirect_timeout_seconds: float = Field(default=10, gt=0)
    extraction_claim_minutes: int = Field(default=10, gt=0)
    extraction_claim_heartbeat_seconds: int = Field(default=30, gt=0)
    public_cache_recheck_days: int = Field(default=7, gt=0)
    # A job whose worker died stays in parsing until the sweep declares it
    # abandoned. Longer than the claim lease, so a worker that is merely slow
    # is never mistaken for one that is gone.
    import_stale_after_minutes: int = Field(default=32, gt=0)
    import_maintenance_interval_seconds: int = Field(default=30, gt=0)
    import_dispatch_maximum_attempts: int = Field(default=3, gt=0, le=20)
    startup_dependency_attempts: int = Field(default=12, gt=0, le=60)
    startup_dependency_delay_seconds: float = Field(default=5, gt=0, le=60)
    readiness_worker_timeout_seconds: float = Field(default=2, gt=0, le=10)

    rate_limiting_enabled: bool = False
    rate_limit_redis_url: str = "redis://127.0.0.1:6379/2"
    rate_limit_key_prefix: str = Field(
        default="ladle:rate-limit:v1",
        min_length=1,
        max_length=128,
    )
    rate_limit_trusted_proxy_cidrs: str = ""
    rate_limit_global_per_minute: int = Field(default=3_000, gt=0)
    rate_limit_guest_ip_per_hour: int = Field(default=20, gt=0)
    rate_limit_guest_installation_per_day: int = Field(default=5, gt=0)
    rate_limit_refresh_ip_per_minute: int = Field(default=60, gt=0)
    rate_limit_refresh_installation_per_minute: int = Field(default=20, gt=0)
    rate_limit_apple_ip_per_hour: int = Field(default=20, gt=0)
    rate_limit_apple_user_per_hour: int = Field(default=10, gt=0)
    rate_limit_import_ip_per_hour: int = Field(default=60, gt=0)
    rate_limit_import_installation_per_hour: int = Field(default=20, gt=0)
    rate_limit_import_user_per_hour: int = Field(default=20, gt=0)
    rate_limit_recipe_mutation_user_per_minute: int = Field(default=120, gt=0)
    rate_limit_sync_user_per_minute: int = Field(default=120, gt=0)

    celery_enabled: bool = False
    celery_broker_url: str = "redis://127.0.0.1:6379/0"
    celery_result_backend: str = "redis://127.0.0.1:6379/1"
    celery_task_soft_time_limit_seconds: int = Field(default=1500, gt=0)
    celery_task_time_limit_seconds: int = Field(default=1560, gt=0)
    celery_visibility_timeout_seconds: int = Field(default=1800, gt=0)
    celery_import_max_retries: int = Field(default=3, ge=0, le=10)
    celery_import_retry_base_seconds: int = Field(default=5, gt=0)
    celery_import_retry_maximum_seconds: int = Field(default=300, gt=0)
    celery_import_retry_jitter_seconds: int = Field(default=5, ge=0)
    worker_provider_mode: Literal["disabled", "fake", "live"] = "disabled"
    provider_daily_billed_unit_limit: Decimal = Field(
        default=Decimal("1000"),
        gt=0,
    )
    provider_reservation_billed_units: Decimal = Field(default=Decimal("3"), gt=0)
    provider_budget_reservation_minutes: int = Field(default=30, gt=0)
    provider_circuit_failure_threshold: int = Field(default=3, gt=0)
    provider_circuit_cooldown_seconds: int = Field(default=300, gt=0)
    provider_circuit_key_prefix: str = Field(
        default="ladle:provider-circuit:v1",
        min_length=1,
        max_length=128,
    )
    server_media_fallback_enabled: bool = False
    object_storage_enabled: bool = False
    object_storage_endpoint_url: AnyHttpUrl = AnyHttpUrl("http://127.0.0.1:9000")
    object_storage_public_endpoint_url: AnyHttpUrl | None = None
    object_storage_region: str = "us-east-1"
    object_storage_bucket: str = "ladle-private"
    object_storage_access_key: str = "ladle-local"
    object_storage_secret_key: SecretStr = SecretStr("ladle-local-secret")

    # Keyless first rung. Runs before any billed provider; when it satisfies
    # coverage on its own, nothing downstream is called.
    free_acquisition_enabled: bool = True
    free_acquisition_subtitles: bool = True
    free_acquisition_follow_links: bool = True
    ytdlp_binary_path: str | None = None
    ytdlp_cookies_file: str | None = None
    ytdlp_timeout_seconds: float = Field(default=90, gt=0)
    linked_page_timeout_seconds: float = Field(default=12, gt=0)

    # Whisper on the raw audio. Cheap enough to precede the transcript
    # providers, and it reuses the OpenRouter key rather than adding a secret.
    audio_transcription_enabled: bool = True
    transcription_model_id: str = "openai/whisper-large-v3"
    transcription_timeout_seconds: float = Field(default=300, gt=0)
    transcription_max_audio_bytes: int = Field(default=20 * 1024 * 1024, gt=0)
    transcription_max_duration_seconds: float = Field(default=1800, gt=0)

    # Frames read by a vision model, for the silent videos where the method is
    # only ever shown. Cheaper than the visual provider it precedes, and it
    # reuses the media transcription already downloaded.
    frame_analysis_enabled: bool = True
    # Same model as extraction, so a frame is read with the same understanding
    # of what a recipe needs. It is 5x the input and 3x the output price of
    # gemini-2.5-flash, which takes eight frames from roughly $0.002 to
    # $0.009; against extraction's $0.013-0.056 that is still the cheap rung,
    # and it is the rung that decides whether a silent video is `partial` or
    # `inferred`. Re-measure with scripts/measure_cost.py before changing.
    frame_analysis_model_id: str = "google/gemini-3.6-flash"
    frame_analysis_max_frames: int = Field(default=8, gt=0, le=32)
    frame_analysis_timeout_seconds: float = Field(default=120, gt=0)

    supadata_base_url: AnyHttpUrl = AnyHttpUrl("https://api.supadata.ai/v1")
    supadata_timeout_seconds: float = Field(default=30, gt=0)
    supadata_api_key: SecretStr | None = None

    soscripted_base_url: AnyHttpUrl = AnyHttpUrl("https://soscripted.com/api/public")
    # The endpoint blocks while it downloads and transcribes the video; its
    # documented client example uses the same ten-minute request window.
    soscripted_timeout_seconds: float = Field(default=600, gt=0)
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
    # Picked on the quality of the recipe, not the price of the call. It names
    # ingredients precisely and, in a recipe with several sub-preparations,
    # says which one each amount belongs to — "soy sauce (for the marinade)"
    # against three other soy sauce lines. The previous model listed the same
    # four amounts unlabelled and double-counted batter it had already listed.
    # It costs about a quarter more per import; see scripts/measure_cost.py.
    openrouter_model_id: str = "google/gemini-3.6-flash"
    # A 35-ingredient recipe with four sub-preparations ran past 8192 and came
    # back truncated, which the extractor can only report as a failed import.
    # Cost is charged per token emitted, not per token allowed, so a headroom
    # that is never reached is free — and stopping mid-recipe never is.
    openrouter_max_tokens: int = Field(default=32_768, gt=0)

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
    google_enabled: bool = False
    google_server_client_id: str | None = None
    google_jwks_url: AnyHttpUrl = AnyHttpUrl(
        "https://www.googleapis.com/oauth2/v3/certs"
    )
    google_timeout_seconds: float = Field(default=10, gt=0)
    google_identity_token_maximum_age_minutes: int = Field(default=10, gt=0)
    google_clock_skew_seconds: int = Field(default=30, ge=0)

    @property
    def app_attest_app_id(self) -> str | None:
        if self.app_attest_app_id_prefix is None or self.app_attest_bundle_id is None:
            return None
        return f"{self.app_attest_app_id_prefix}.{self.app_attest_bundle_id}"

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
    def validate_import_quotas(self) -> Self:
        if self.user_import_monthly_quota < self.user_import_daily_quota:
            raise ValueError("monthly import quota must be at least the daily quota")
        return self

    @model_validator(mode="after")
    def validate_worker_timing(self) -> Self:
        claim_seconds = self.extraction_claim_minutes * 60
        stale_seconds = self.import_stale_after_minutes * 60
        reservation_seconds = self.import_reservation_minutes * 60
        budget_reservation_seconds = self.provider_budget_reservation_minutes * 60
        longest_provider_timeout = max(
            self.ytdlp_timeout_seconds,
            self.linked_page_timeout_seconds,
            self.transcription_timeout_seconds,
            self.frame_analysis_timeout_seconds,
            self.supadata_timeout_seconds,
            self.soscripted_timeout_seconds,
            self.anthropic_timeout_seconds,
            self.openrouter_timeout_seconds,
        )
        safe = (
            self.extraction_claim_heartbeat_seconds * 2 < claim_seconds
            and longest_provider_timeout
            < self.celery_task_soft_time_limit_seconds
            < self.celery_task_time_limit_seconds
            < self.celery_visibility_timeout_seconds
            < stale_seconds
            < reservation_seconds
            and self.celery_task_time_limit_seconds < budget_reservation_seconds
        )
        if not safe:
            raise ValueError(
                "worker timing must satisfy heartbeat*2 < claim lease, longest "
                "provider timeout < soft task limit < hard task limit < broker "
                "visibility < stale-job timeout < recipe reservation, and hard "
                "task limit < provider budget reservation"
            )
        if (
            self.celery_import_retry_maximum_seconds
            < self.celery_import_retry_base_seconds
        ):
            raise ValueError(
                "worker timing requires retry maximum to be at least retry base"
            )
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
        if not self.celery_enabled:
            raise ValueError("production requires Celery")
        if self.worker_provider_mode != "live":
            raise ValueError("production requires live worker provider mode")
        for field_name in (
            "celery_broker_url",
            "celery_result_backend",
            "rate_limit_redis_url",
        ):
            self._require_tls_url(field_name, getattr(self, field_name), {"rediss"})
            self._require_url_password(field_name, getattr(self, field_name))
        database = urlsplit(self.database_url)
        ssl_mode = parse_qs(database.query).get("sslmode", [])
        if database.scheme != "postgresql+psycopg" or not {
            "require",
            "verify-ca",
            "verify-full",
        }.intersection(ssl_mode):
            raise ValueError(
                "production database_url must use psycopg with TLS sslmode"
            )
        self._require_url_password("database_url", self.database_url)
        if not self.object_storage_enabled:
            raise ValueError("production requires object storage")
        self._require_tls_url(
            "object_storage_endpoint_url",
            str(self.object_storage_endpoint_url),
            {"https"},
        )
        if self.object_storage_public_endpoint_url is not None:
            self._require_tls_url(
                "object_storage_public_endpoint_url",
                str(self.object_storage_public_endpoint_url),
                {"https"},
            )
        storage_access = self.object_storage_access_key.strip()
        if len(storage_access) < 8 or self._is_placeholder(storage_access):
            raise ValueError(
                "object_storage_access_key must be non-placeholder in production"
            )
        storage_secret = self.object_storage_secret_key.get_secret_value().strip()
        if len(
            storage_secret
        ) < _MINIMUM_PRODUCTION_SECRET_LENGTH or self._is_placeholder(storage_secret):
            raise ValueError(
                "object_storage_secret_key must be a non-placeholder secret "
                "of at least 32 characters in production"
            )
        if not self.attestation_enforced:
            raise ValueError("App Attest enforcement is required in production")
        if self.app_attest_app_id is None:
            raise ValueError(
                "App Attest App ID prefix and bundle ID are required in production"
            )
        if self.app_attest_environment != "production":
            raise ValueError(
                "the production App Attest environment is required in production"
            )
        if not self.rate_limiting_enabled:
            raise ValueError("distributed rate limiting is required in production")
        extraction_key = (
            "openrouter_api_key"
            if self.extraction_provider == "openrouter"
            else "anthropic_api_key"
        )
        extraction_secret = getattr(self, extraction_key)
        if extraction_secret is None or self._is_placeholder(
            extraction_secret.get_secret_value()
        ):
            raise ValueError(
                f"production live workers require a configured {extraction_key}"
            )
        for field_name in (
            "supadata_base_url",
            "soscripted_base_url",
            "anthropic_base_url",
            "openrouter_base_url",
            "apple_jwks_url",
            "apple_token_url",
            "google_jwks_url",
        ):
            self._require_tls_url(field_name, str(getattr(self, field_name)), {"https"})
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
        if self.google_enabled and not self.google_server_client_id:
            raise ValueError("Google sign-in requires a server OAuth client ID")
        return self

    @staticmethod
    def _is_placeholder(value: str) -> bool:
        normalized = value.strip().casefold()
        return not normalized or any(
            normalized.startswith(prefix) for prefix in _PLACEHOLDER_PREFIXES
        )

    @classmethod
    def _require_tls_url(
        cls,
        field_name: str,
        value: str,
        schemes: set[str],
    ) -> None:
        if urlsplit(value).scheme.casefold() not in schemes:
            raise ValueError(
                f"production {field_name} must use a TLS scheme: "
                f"{', '.join(sorted(schemes))}"
            )

    @classmethod
    def _require_url_password(cls, field_name: str, value: str) -> None:
        password = urlsplit(value).password or ""
        if len(password) < 16 or cls._is_placeholder(password):
            raise ValueError(
                f"production {field_name} must contain non-placeholder credentials"
            )
