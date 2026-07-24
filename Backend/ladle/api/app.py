from datetime import timedelta

import httpx
from fastapi import FastAPI
from sqlalchemy.orm import Session, sessionmaker

from ladle.api.routes.auth import router as auth_router
from ladle.api.routes.imports import router as imports_router
from ladle.api.routes.recipes import router as recipes_router
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.clock import Clock, SystemClock
from ladle.config import Settings
from ladle.db.session import build_engine, build_session_factory
from ladle.imports.admission import AdmissionService
from ladle.imports.dispatcher import (
    CeleryImportDispatcher,
    ImportDispatcher,
    NoopImportDispatcher,
)
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.infrastructure.dns import PinnedRedirectResolver, SystemDNSResolver
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
    settings: Settings | None = None,
) -> FastAPI:
    """Build the HTTP application without eagerly contacting infrastructure."""

    configured = settings or Settings()
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
    database_sessions = session_factory or build_session_factory(
        build_engine(configured.database_url)
    )
    application = FastAPI(
        title="Ladle API",
        version="0.1.0",
        docs_url=None,
        redoc_url=None,
    )
    application.state.session_factory = database_sessions
    application.state.clock = runtime_clock
    application.state.session_service = runtime_sessions
    application.state.access_tokens = token_codec
    application.state.attestation = attestation or AttestationService(
        enforced=configured.attestation_enforced
    )
    application.state.recipe_service = RecipeService(clock=runtime_clock)
    application.state.sync_service = RecipeSyncService()
    redirect_client: httpx.Client | None = None
    if source_parser is None:
        redirect_client = httpx.Client(
            timeout=configured.source_redirect_timeout_seconds
        )
        source_parser = SourceIdentityParser(
            redirect_resolver=PinnedRedirectResolver(
                dns=SystemDNSResolver(),
                client=redirect_client,
            )
        )
    application.state.admission_service = AdmissionService(
        parser=source_parser,
        reservations=ReservationService(
            clock=runtime_clock,
            lifetime=timedelta(minutes=configured.import_reservation_minutes),
        ),
        clock=runtime_clock,
    )
    if import_dispatcher is not None:
        application.state.import_dispatcher = import_dispatcher
    elif configured.celery_enabled:
        application.state.import_dispatcher = CeleryImportDispatcher.from_broker(
            configured.celery_broker_url
        )
    else:
        application.state.import_dispatcher = NoopImportDispatcher()
    application.include_router(auth_router)
    application.include_router(recipes_router)
    application.include_router(imports_router)
    if redirect_client is not None:
        application.router.add_event_handler("shutdown", redirect_client.close)
    return application


app = create_app()
