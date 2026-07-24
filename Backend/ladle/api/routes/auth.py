from typing import Annotated, cast

from fastapi import APIRouter, Header, HTTPException, Request, Response, status
from pydantic import Field
from sqlalchemy.orm import Session

from ladle.auth.attestation import AttestationRejected, AttestationService
from ladle.auth.guest import register_guest
from ladle.auth.sessions import (
    RefreshTokenInvalid,
    SessionService,
    SessionTokens,
)
from ladle.auth.tokens import (
    AccessClaims,
    AccessTokenCodec,
    AccessTokenInvalid,
)
from ladle.clock import Clock
from ladle.contracts.common import WireDateTime, WireModel, WireUUID
from ladle.db.models import AuthSession

router = APIRouter(prefix="/v1/auth", tags=["auth"])


class GuestAuthRequest(WireModel):
    installation_id: str = Field(min_length=1, max_length=255)
    attestation: str | None = None


class RefreshRequest(WireModel):
    refresh_token: str
    device_id: WireUUID


class AuthTokensResponse(WireModel):
    access_token: str
    access_token_expires_at: WireDateTime
    refresh_token: str | None
    user_id: WireUUID
    device_id: WireUUID
    user_kind: str

    @classmethod
    def from_tokens(cls, value: SessionTokens) -> "AuthTokensResponse":
        return cls(
            access_token=value.access_token,
            access_token_expires_at=value.access_expires_at,
            refresh_token=value.refresh_token,
            user_id=value.user_id,
            device_id=value.device_id,
            user_kind=value.user_kind,
        )


def _database(request: Request) -> Session:
    return cast(Session, request.app.state.session_factory())


def _clock(request: Request) -> Clock:
    return cast(Clock, request.app.state.clock)


def _sessions(request: Request) -> SessionService:
    return cast(SessionService, request.app.state.session_service)


def _attestation(request: Request) -> AttestationService:
    return cast(AttestationService, request.app.state.attestation)


def _access_tokens(request: Request) -> AccessTokenCodec:
    return cast(AccessTokenCodec, request.app.state.access_tokens)


def access_claims(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> AccessClaims:
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    try:
        claims = _access_tokens(request).decode(
            authorization.removeprefix("Bearer "),
            now=_clock(request).now(),
        )
    except AccessTokenInvalid as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from error

    with _database(request) as database:
        stored = database.get(AuthSession, claims.session_id)
        if (
            stored is None
            or stored.revoked_at is not None
            or stored.user_id != claims.user_id
            or stored.device_id != claims.device_id
        ):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    return claims


@router.post(
    "/guest",
    response_model=AuthTokensResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_guest(request: Request, body: GuestAuthRequest) -> AuthTokensResponse:
    try:
        with _database(request) as database, database.begin():
            tokens = register_guest(
                database,
                installation_id=body.installation_id,
                assertion=body.attestation,
                attestation=_attestation(request),
                sessions=_sessions(request),
                clock=_clock(request),
            )
    except AttestationRejected as error:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN) from error
    return AuthTokensResponse.from_tokens(tokens)


@router.post("/refresh", response_model=AuthTokensResponse)
def refresh_session(request: Request, body: RefreshRequest) -> AuthTokensResponse:
    authentication_error: RefreshTokenInvalid | None = None
    tokens: SessionTokens | None = None
    with _database(request) as database, database.begin():
        try:
            tokens = _sessions(request).refresh(
                database,
                refresh_token=body.refresh_token,
                device_id=body.device_id,
            )
        except RefreshTokenInvalid as error:
            authentication_error = error

    if authentication_error is not None or tokens is None:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    return AuthTokensResponse.from_tokens(tokens)


@router.delete("/session", status_code=status.HTTP_204_NO_CONTENT)
def delete_session(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    claims = access_claims(request, authorization)
    with _database(request) as database, database.begin():
        _sessions(request).revoke(database, session_id=claims.session_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
