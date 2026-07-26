from typing import Annotated, cast

from fastapi import APIRouter, Header, HTTPException, Request, Response, status
from pydantic import Field

from ladle.api.dependencies import clock as request_clock
from ladle.api.dependencies import database
from ladle.auth.apple import (
    AppleAuthorizationCodeInvalid,
    AppleCredentials,
    AppleIdentityTokenInvalid,
)
from ladle.auth.attestation import (
    AppAttestEvidence,
    AttestationRejected,
    AttestationService,
)
from ladle.auth.guest import register_guest
from ladle.auth.merge import AccountMergeInvalid, AccountMergeService
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
from ladle.contracts.common import WireDateTime, WireModel, WireUUID
from ladle.db.models import AuthSession, Device

router = APIRouter(prefix="/v1/auth", tags=["auth"])


class GuestAuthRequest(WireModel):
    installation_id: str = Field(min_length=1, max_length=255)
    attestation: AppAttestEvidence | None = None


class RefreshRequest(WireModel):
    refresh_token: str
    device_id: WireUUID


class AppleAuthRequest(WireModel):
    identity_token: str = Field(min_length=1, max_length=16_384)
    authorization_code: str = Field(min_length=1, max_length=8_192)
    nonce: str = Field(min_length=1, max_length=512)
    idempotency_key: str = Field(min_length=1, max_length=255)


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


def _sessions(request: Request) -> SessionService:
    return cast(SessionService, request.app.state.session_service)


def _attestation(request: Request) -> AttestationService:
    return cast(AttestationService, request.app.state.attestation)


def _access_tokens(request: Request) -> AccessTokenCodec:
    return cast(AccessTokenCodec, request.app.state.access_tokens)


def _apple_credentials(request: Request) -> AppleCredentials | None:
    return cast(
        AppleCredentials | None,
        request.app.state.apple_credentials,
    )


def _account_merger(request: Request) -> AccountMergeService:
    return cast(AccountMergeService, request.app.state.account_merge_service)


def access_claims(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> AccessClaims:
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
    try:
        claims = _access_tokens(request).decode(
            authorization.removeprefix("Bearer "),
            now=request_clock(request).now(),
        )
    except AccessTokenInvalid as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from error

    with database(request) as current_database:
        stored = current_database.get(AuthSession, claims.session_id)
        device = current_database.get(Device, claims.device_id)
        if (
            stored is None
            or device is None
            or device.attestation_state == "revoked"
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
    rejection: AttestationRejected | None = None
    tokens: SessionTokens | None = None
    with database(request) as current_database, current_database.begin():
        try:
            tokens = register_guest(
                current_database,
                installation_id=body.installation_id,
                evidence=body.attestation,
                attestation=_attestation(request),
                sessions=_sessions(request),
                clock=request_clock(request),
            )
        except AttestationRejected as error:
            rejection = error
    if rejection is not None or tokens is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN) from rejection
    return AuthTokensResponse.from_tokens(tokens)


@router.post("/apple", response_model=AuthTokensResponse)
def sign_in_with_apple(
    request: Request,
    body: AppleAuthRequest,
    authorization: Annotated[str | None, Header()] = None,
) -> AuthTokensResponse:
    claims = access_claims(request, authorization)
    credentials = _apple_credentials(request)
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE)
    try:
        credential = credentials.verify(
            identity_token=body.identity_token,
            authorization_code=body.authorization_code,
            nonce=body.nonce,
        )
    except (AppleIdentityTokenInvalid, AppleAuthorizationCodeInvalid) as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from error

    try:
        with database(request) as current_database, current_database.begin():
            destination_id = _account_merger(request).merge(
                current_database,
                guest_user_id=claims.user_id,
                apple_subject=credential.subject,
                idempotency_key=body.idempotency_key,
            )
            tokens = _sessions(request).create(
                current_database,
                user_id=destination_id,
                device_id=claims.device_id,
            )
    except AccountMergeInvalid as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT) from error
    return AuthTokensResponse.from_tokens(tokens)


@router.post("/refresh", response_model=AuthTokensResponse)
def refresh_session(request: Request, body: RefreshRequest) -> AuthTokensResponse:
    authentication_error: RefreshTokenInvalid | None = None
    tokens: SessionTokens | None = None
    with database(request) as current_database, current_database.begin():
        try:
            tokens = _sessions(request).refresh(
                current_database,
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
    with database(request) as current_database, current_database.begin():
        _sessions(request).revoke(
            current_database,
            session_id=claims.session_id,
        )
    return Response(status_code=status.HTTP_204_NO_CONTENT)
