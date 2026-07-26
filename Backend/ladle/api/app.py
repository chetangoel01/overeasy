from collections.abc import Awaitable, Callable
from datetime import timedelta

import httpx
from celery import Celery
from fastapi import FastAPI, Request, Response
from redis import Redis
from sqlalchemy import Engine
from sqlalchemy.orm import Session, sessionmaker

from ladle.api.errors import install_error_handlers, rate_limit_response
from ladle.api.rate_limits import (
    ClientIPResolver,
    NullRateLimitBackend,
    RateLimitBackend,
    RateLimitExceeded,
    RateLimitPolicies,
    RateLimitService,
    RedisTokenBucketBackend,
)
from ladle.api.request_limits import RequestBodyLimitMiddleware
from ladle.api.routes.attestation import router as attestation_router
from ladle.api.routes.auth import router as auth_router
from ladle.api.routes.health import (
    CeleryWorkerReadinessProbe,
    DatabaseReadinessProbe,
    MetricsAccessPolicy,
    ProductionConfigurationReadinessProbe,
    ReadinessProbe,
    ReadinessService,
    RedisReadinessProbe,
    StartupDependencyGate,
    StorageReadinessProbe,
)
from ladle.api.routes.health import router as health_router
from ladle.api.routes.imports import router as imports_router
from ladle.api.routes.recipes import router as recipes_router
from ladle.auth.apple import (
    AppleAuthorizationCodeClient,
    AppleCredentials,
    AppleCredentialService,
    AppleIdentityTokenVerifier,
    HTTPAppleJWKS,
)
from ladle.auth.attestation import AppleAppAttestVerifier, AttestationService
from ladle.auth.deletion import AccountDeletionService
from ladle.auth.google import (
    GoogleCredentials,
    GoogleCredentialService,
    GoogleIdentityTokenVerifier,
    HTTPGoogleJWKS,
)
from ladle.auth.merge import AccountMergeService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.clock import Clock, SystemClock
from ladle.config import Settings
from ladle.crypto.private_text import build_private_text_cipher
from ladle.db.session import build_engine, build_session_factory
from ladle.imports.admission import AdmissionService
from ladle.imports.dispatcher import (
    CeleryImportDispatcher,
    ImportDispatcher,
    NoopImportDispatcher,
)
from ladle.imports.outbox import DispatchOutboxService
from ladle.imports.quotas import ImportQuotaService
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.imports.transitions import ImportRetryService
from ladle.infrastructure.dns import PinnedRedirectResolver, SystemDNSResolver
from ladle.infrastructure.object_storage import S3ObjectStorage
from ladle.observability.metrics import MetricsRegistry, RedisMetricsBackend
from ladle.observability.middleware import install_request_middleware
from ladle.observability.structured_logging import configure_structured_logging
from ladle.observability.tracing import instrument_application
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService
from ladle.sync.service import RecipeSyncService


def create_app(
    *,
    session_factory: sessionmaker[Session] | None = None,
    clock: Clock | None = None,
    session_service: SessionService | None = None,
    access_tokens: AccessTokenCodec | None = None,
    attestation: AttestationService | None = None,
    import_dispatcher: ImportDispatcher | None = None,
    source_parser: SourceIdentityParser | None = None,
    apple_credentials: AppleCredentials | None = None,
    google_credentials: GoogleCredentials | None = None,
    readiness_probes: dict[str, ReadinessProbe] | None = None,
    metrics: MetricsRegistry | None = None,
    rate_limit_backend: RateLimitBackend | None = None,
    settings: Settings | None = None,
) -> FastAPI:
    """Build the HTTP application without eagerly contacting infrastructure."""

    configured = settings or Settings()
    if configured.environment == "production" and configured.structured_logging_enabled:
        configure_structured_logging(level=configured.log_level)
    runtime_clock = clock or SystemClock()
    token_codec = access_tokens or AccessTokenCodec(
        signing_secret=configured.jwt_signing_secret.get_secret_value(),
        issuer=configured.access_token_issuer,
        lifetime=timedelta(minutes=configured.access_token_minutes),
    )
    runtime_sessions = session_service or SessionService(
        access_tokens=token_codec,
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=configured.refresh_token_days),
        rotation_grace=timedelta(seconds=configured.refresh_rotation_grace_seconds),
        clock=runtime_clock,
    )
    database_engine: Engine | None = None
    if session_factory is None:
        database_engine = build_engine(configured.database_url)
        database_sessions = build_session_factory(database_engine)
    else:
        database_sessions = session_factory
    application = FastAPI(
        title="Ladle API",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
    )
    application.add_middleware(
        RequestBodyLimitMiddleware,
        maximum_bytes=configured.maximum_request_body_bytes,
    )
    application.state.session_factory = database_sessions
    application.state.clock = runtime_clock
    application.state.session_service = runtime_sessions
    application.state.access_tokens = token_codec
    runtime_attestation = attestation
    if runtime_attestation is None:
        verifier = (
            AppleAppAttestVerifier(
                app_id=configured.app_attest_app_id,
                environment=configured.app_attest_environment,
                clock=runtime_clock,
            )
            if configured.app_attest_app_id is not None
            else None
        )
        runtime_attestation = AttestationService(
            enforced=configured.attestation_enforced,
            verifier=verifier,
            clock=runtime_clock,
            challenge_lifetime=timedelta(
                seconds=configured.app_attest_challenge_seconds
            ),
        )
    if configured.environment == "production" and (
        not runtime_attestation.enforced or not runtime_attestation.configured
    ):
        raise RuntimeError(
            "production requires an enabled, configured App Attest verifier"
        )
    application.state.attestation = runtime_attestation
    metrics_redis: Redis | None = None
    if metrics is not None:
        runtime_metrics = metrics
    elif configured.durable_metrics_enabled:
        metrics_redis = Redis.from_url(configured.metrics_redis_url)
        runtime_metrics = MetricsRegistry(
            backend=RedisMetricsBackend(
                metrics_redis,
                prefix=configured.metrics_key_prefix,
            )
        )
    else:
        runtime_metrics = MetricsRegistry()
    application.state.metrics = runtime_metrics
    application.state.metrics_access = MetricsAccessPolicy(
        configured.metrics_auth_token.get_secret_value()
        if configured.metrics_auth_token is not None
        else None
    )
    rate_limit_redis: Redis | None = None
    if rate_limit_backend is None:
        if configured.rate_limiting_enabled:
            rate_limit_redis = Redis.from_url(configured.rate_limit_redis_url)
            rate_limit_backend = RedisTokenBucketBackend(
                rate_limit_redis,
                prefix=configured.rate_limit_key_prefix,
            )
        else:
            rate_limit_backend = NullRateLimitBackend()
    application.state.rate_limits = RateLimitService(
        rate_limit_backend,
        client_ips=ClientIPResolver(configured.rate_limit_trusted_proxy_cidrs),
        metrics=runtime_metrics,
    )
    application.state.rate_limit_policies = RateLimitPolicies.from_settings(configured)
    object_storage: S3ObjectStorage | None = None
    if configured.object_storage_enabled:
        object_storage = S3ObjectStorage(
            endpoint_url=str(configured.object_storage_endpoint_url),
            region=configured.object_storage_region,
            bucket=configured.object_storage_bucket,
            access_key=configured.object_storage_access_key,
            secret_key=configured.object_storage_secret_key.get_secret_value(),
            public_endpoint_url=(
                str(configured.object_storage_public_endpoint_url)
                if configured.object_storage_public_endpoint_url is not None
                else None
            ),
        )
    object_url: Callable[[str], str] | None = None
    if object_storage is not None:
        signing_storage = object_storage

        def object_url(key: str) -> str:
            return signing_storage.signed_read_url(key, expires_in=timedelta(hours=6))

    recipe_repository = RecipeRepository(object_url=object_url)
    application.state.recipe_service = RecipeService(
        clock=runtime_clock,
        repository=recipe_repository,
    )
    application.state.sync_service = RecipeSyncService(
        recipe_repository,
        metrics=runtime_metrics,
    )
    readiness_redis: list[Redis] = []
    default_probes: dict[str, ReadinessProbe] = {
        "configuration": ProductionConfigurationReadinessProbe(configured),
        "database": DatabaseReadinessProbe(database_sessions),
    }
    if configured.celery_enabled:
        broker_redis = Redis.from_url(configured.celery_broker_url)
        result_redis = Redis.from_url(configured.celery_result_backend)
        readiness_redis.extend([broker_redis, result_redis])
        default_probes["broker"] = RedisReadinessProbe(broker_redis)
        default_probes["celeryResult"] = RedisReadinessProbe(result_redis)
        readiness_celery = Celery(
            "ladle-api-readiness",
            broker=configured.celery_broker_url,
        )
        default_probes["worker"] = CeleryWorkerReadinessProbe(
            readiness_celery.control,
            timeout_seconds=configured.readiness_worker_timeout_seconds,
        )
    if configured.rate_limiting_enabled:
        readiness_rate_redis = rate_limit_redis or Redis.from_url(
            configured.rate_limit_redis_url
        )
        if readiness_rate_redis is not rate_limit_redis:
            readiness_redis.append(readiness_rate_redis)
        default_probes["rateLimitRedis"] = RedisReadinessProbe(readiness_rate_redis)
    if configured.durable_metrics_enabled:
        readiness_metrics_redis = metrics_redis or Redis.from_url(
            configured.metrics_redis_url
        )
        if readiness_metrics_redis is not metrics_redis:
            readiness_redis.append(readiness_metrics_redis)
        default_probes["metricsRedis"] = RedisReadinessProbe(readiness_metrics_redis)
    if object_storage is not None:
        default_probes["storage"] = StorageReadinessProbe(object_storage)
    application.state.object_storage = object_storage
    runtime_readiness = ReadinessService(
        readiness_probes if readiness_probes is not None else default_probes
    )
    application.state.readiness = runtime_readiness
    if configured.environment == "production":
        startup_gate = StartupDependencyGate(
            runtime_readiness,
            attempts=configured.startup_dependency_attempts,
            delay_seconds=configured.startup_dependency_delay_seconds,
        )
        application.router.add_event_handler("startup", startup_gate.wait)
    private_text = build_private_text_cipher(
        active_key_id=configured.data_encryption_active_key_id,
        keyring_json=configured.data_encryption_keyring,
        legacy_key=configured.data_encryption_key,
    )
    application.state.private_text = private_text
    apple_client: httpx.Client | None = None
    if apple_credentials is None and configured.apple_enabled:
        if (
            configured.apple_team_id is None
            or configured.apple_key_id is None
            or configured.apple_private_key is None
        ):
            raise RuntimeError("Apple sign-in credentials are incomplete")
        apple_client = httpx.Client(
            timeout=configured.apple_timeout_seconds,
            trust_env=False,
        )
        apple_credentials = AppleCredentialService(
            identity_tokens=AppleIdentityTokenVerifier(
                jwks=HTTPAppleJWKS(
                    http=apple_client,
                    url=str(configured.apple_jwks_url),
                ),
                audience=configured.apple_bundle_id,
                clock=runtime_clock,
                maximum_age=timedelta(
                    minutes=configured.apple_identity_token_maximum_age_minutes
                ),
                clock_skew=timedelta(seconds=configured.apple_clock_skew_seconds),
            ),
            authorization_codes=AppleAuthorizationCodeClient(
                http=apple_client,
                team_id=configured.apple_team_id,
                key_id=configured.apple_key_id,
                private_key=configured.apple_private_key.get_secret_value(),
                client_id=configured.apple_bundle_id,
                token_url=str(configured.apple_token_url),
                clock=runtime_clock,
            ),
        )
    application.state.apple_credentials = apple_credentials
    google_client: httpx.Client | None = None
    if google_credentials is None and configured.google_enabled:
        if configured.google_server_client_id is None:
            raise RuntimeError("Google sign-in credentials are incomplete")
        google_client = httpx.Client(
            timeout=configured.google_timeout_seconds,
            trust_env=False,
        )
        google_credentials = GoogleCredentialService(
            GoogleIdentityTokenVerifier(
                jwks=HTTPGoogleJWKS(
                    http=google_client,
                    url=str(configured.google_jwks_url),
                ),
                audience=configured.google_server_client_id,
                clock=runtime_clock,
                maximum_age=timedelta(
                    minutes=configured.google_identity_token_maximum_age_minutes
                ),
                clock_skew=timedelta(seconds=configured.google_clock_skew_seconds),
            )
        )
    application.state.google_credentials = google_credentials
    application.state.account_merge_service = AccountMergeService(clock=runtime_clock)
    application.state.account_deletion = AccountDeletionService(
        session_factory=database_sessions,
        sessions=runtime_sessions,
        clock=runtime_clock,
        audit_secret=configured.jwt_signing_secret.get_secret_value(),
        private_text=private_text,
        apple_credentials=apple_credentials,
    )
    redirect_client: httpx.Client | None = None
    if source_parser is None:
        redirect_client = httpx.Client(
            timeout=configured.source_redirect_timeout_seconds,
            trust_env=False,
        )
        source_parser = SourceIdentityParser(
            redirect_resolver=PinnedRedirectResolver(
                dns=SystemDNSResolver(),
                client=redirect_client,
            )
        )
    reservations = ReservationService(
        clock=runtime_clock,
        lifetime=timedelta(minutes=configured.import_reservation_minutes),
    )
    import_quota = ImportQuotaService(
        clock=runtime_clock,
        daily_limit=configured.user_import_daily_quota,
        monthly_limit=configured.user_import_monthly_quota,
    )
    dispatch_outbox = DispatchOutboxService(
        session_factory=database_sessions,
        clock=runtime_clock,
        stale_after=timedelta(minutes=configured.import_stale_after_minutes),
        maximum_dispatches=configured.import_dispatch_maximum_attempts,
    )
    application.state.dispatch_outbox = dispatch_outbox
    application.state.admission_service = AdmissionService(
        parser=source_parser,
        reservations=reservations,
        clock=runtime_clock,
        private_text=private_text,
        quota=import_quota,
        outbox=dispatch_outbox,
    )
    application.state.import_retry_service = ImportRetryService(
        clock=runtime_clock,
        reservations=reservations,
        private_text=private_text,
        quota=import_quota,
        outbox=dispatch_outbox,
    )
    if import_dispatcher is not None:
        application.state.import_dispatcher = import_dispatcher
    elif configured.celery_enabled:
        application.state.import_dispatcher = CeleryImportDispatcher.from_broker(
            configured.celery_broker_url
        )
    else:
        application.state.import_dispatcher = NoopImportDispatcher()
    application.include_router(attestation_router)
    application.include_router(auth_router)
    application.include_router(recipes_router)
    application.include_router(imports_router)
    application.include_router(health_router)
    install_error_handlers(application)

    @application.middleware("http")
    async def global_rate_limit(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        try:
            application.state.rate_limits.enforce(
                application.state.rate_limit_policies.global_request()
            )
        except RateLimitExceeded as error:
            return rate_limit_response(
                request,
                retry_after_seconds=error.retry_after_seconds,
            )
        return await call_next(request)

    install_request_middleware(
        application,
        metrics=application.state.metrics,
    )
    if configured.tracing_enabled:
        tracer_provider = instrument_application(
            application,
            settings=configured,
            engine=database_engine,
            instrument_dependencies=True,
        )
        application.state.tracer_provider = tracer_provider
        application.router.add_event_handler("shutdown", tracer_provider.shutdown)
    if redirect_client is not None:
        application.router.add_event_handler("shutdown", redirect_client.close)
    if apple_client is not None:
        application.router.add_event_handler("shutdown", apple_client.close)
    if google_client is not None:
        application.router.add_event_handler("shutdown", google_client.close)
    if rate_limit_redis is not None:
        application.router.add_event_handler("shutdown", rate_limit_redis.close)
    if metrics_redis is not None:
        application.router.add_event_handler("shutdown", metrics_redis.close)
    for readiness_client in readiness_redis:
        if readiness_client is not rate_limit_redis:
            application.router.add_event_handler(
                "shutdown",
                readiness_client.close,
            )
    return application


app = create_app()
