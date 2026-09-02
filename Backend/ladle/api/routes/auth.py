from collections.abc import Callable
from typing import Annotated, Literal, cast
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Request, Response, status
from pydantic import Field

from ladle.api.dependencies import clock as request_clock
from ladle.api.dependencies import database
from ladle.api.rate_limits import RateLimitPolicies, RateLimitService
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
from ladle.auth.deletion import AccountDeletionService, AccountDeletionUnavailable
from ladle.auth.google import (
    GoogleCredentials,
    GoogleIdentityTokenInvalid,
)
from ladle.auth.guest import register_guest, release_device_binding
from ladle.auth.merge import (
    AccountMergeInvalid,
    AccountMergeService,
    SignInProfile,
)
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
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import AuthSession, Device, User

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
    # Apple returns a full name exactly once, in the client's credential on
    # the first authorization. It is in no token and cannot be fetched later,
    # so the client forwards it or it is lost. Client-asserted, which is
    # acceptable because the cook can edit it anyway — but still bounded.
    full_name: str | None = Field(default=None, max_length=64)


class GoogleAuthRequest(WireModel):
    identity_token: str = Field(min_length=1, max_length=16_384)
    idempotency_key: str = Field(min_length=1, max_length=255)


class ProfileUpdateRequest(WireModel):
    display_name: str | None = Field(default=None, max_length=64)


class ProfileResponse(WireModel):
    user_kind: str
    display_name: str | None = None
    avatar_url: str | None = None
    # Server-owned, and absent from `ProfileUpdateRequest` on purpose: an
    # account's start date is not something its owner gets to assert.
    created_at: WireDateTime


class AccountDeletionRequest(WireModel):
    confirmation: Literal["DELETE"]
    refresh_token: str = Field(min_length=1, max_length=2048)
    idempotency_key: str = Field(min_length=1, max_length=255)


class AuthTokensResponse(WireModel):
    access_token: str
    access_token_expires_at: WireDateTime
    refresh_token: str | None
    user_id: WireUUID
    device_id: WireUUID
    user_kind: str
    # The profile travels with the tokens rather than behind a `/me` call, so
    # every refresh keeps it current for free. The creation date rides along
    # for the same reason, and because it never changes it costs nothing to
    # repeat.
    created_at: WireDateTime
    display_name: str | None = None
    avatar_url: str | None = None

    @classmethod
    def from_tokens(cls, value: SessionTokens) -> "AuthTokensResponse":
        return cls(
            access_token=value.access_token,
            access_token_expires_at=value.access_expires_at,
            refresh_token=value.refresh_token,
            user_id=value.user_id,
            device_id=value.device_id,
            user_kind=value.user_kind,
            created_at=value.created_at,
            display_name=value.display_name,
            avatar_url=value.avatar_url,
        )


def _trimmed(value: str | None) -> str | None:
    """A forwarded name, or `None` if it is blank once trimmed."""
    if value is None:
        return None
    stripped = value.strip()
    return stripped or None


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


def _google_credentials(request: Request) -> GoogleCredentials | None:
    return cast(
        GoogleCredentials | None,
        request.app.state.google_credentials,
    )


def _account_merger(request: Request) -> AccountMergeService:
    return cast(AccountMergeService, request.app.state.account_merge_service)


def _private_text(request: Request) -> PrivateTextCipher:
    return cast(PrivateTextCipher, request.app.state.private_text)


def _rate_limits(request: Request) -> RateLimitService:
    return cast(RateLimitService, request.app.state.rate_limits)


def _rate_limit_policies(request: Request) -> RateLimitPolicies:
    return cast(RateLimitPolicies, request.app.state.rate_limit_policies)


def _user_log_identifier(request: Request) -> Callable[[UUID], str]:
    return cast(
        Callable[[UUID], str],
        request.app.state.user_log_identifier,
    )


def decoded_access_claims(
    request: Request,
    authorization: str | None,
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
    return claims


def access_claims(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> AccessClaims:
    claims = decoded_access_claims(request, authorization)

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
    request.state.user_safe_id = _user_log_identifier(request)(claims.user_id)
    return claims


def _account_deletion(request: Request) -> AccountDeletionService:
    return cast(AccountDeletionService, request.app.state.account_deletion)


@router.post(
    "/guest",
    response_model=AuthTokensResponse,
    status_code=status.HTTP_201_CREATED,
)
def create_guest(request: Request, body: GuestAuthRequest) -> AuthTokensResponse:
    limits = _rate_limits(request)
    limits.enforce(
        _rate_limit_policies(request).guest(
            limits.client_ip(request),
            body.installation_id,
        )
    )
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
    limits = _rate_limits(request)
    limits.enforce(
        _rate_limit_policies(request).apple(
            limits.client_ip(request),
            str(claims.user_id),
        )
    )
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
                apple_refresh_token_encrypted=(
                    _private_text(request).encrypt(credential.refresh_token)
                    if credential.refresh_token is not None
                    else None
                ),
                profile=SignInProfile(display_name=_trimmed(body.full_name)),
            )
            tokens = _sessions(request).create(
                current_database,
                user_id=destination_id,
                device_id=claims.device_id,
            )
    except AccountMergeInvalid as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT) from error
    return AuthTokensResponse.from_tokens(tokens)


@router.post("/google", response_model=AuthTokensResponse)
def sign_in_with_google(
    request: Request,
    body: GoogleAuthRequest,
    authorization: Annotated[str | None, Header()] = None,
) -> AuthTokensResponse:
    claims = access_claims(request, authorization)
    limits = _rate_limits(request)
    limits.enforce(
        _rate_limit_policies(request).google(
            limits.client_ip(request),
            str(claims.user_id),
        )
    )
    credentials = _google_credentials(request)
    if credentials is None:
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE)
    try:
        credential = credentials.verify(body.identity_token)
    except GoogleIdentityTokenInvalid as error:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from error

    try:
        with database(request) as current_database, current_database.begin():
            destination_id = _account_merger(request).merge_google(
                current_database,
                guest_user_id=claims.user_id,
                google_subject=credential.subject,
                idempotency_key=body.idempotency_key,
                profile=SignInProfile(
                    display_name=credential.name,
                    avatar_url=credential.picture,
                ),
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
    limits = _rate_limits(request)
    limits.enforce(
        _rate_limit_policies(request).refresh(
            limits.client_ip(request),
            str(body.device_id),
        )
    )
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


@router.patch("/profile", response_model=ProfileResponse)
def update_profile(
    request: Request,
    body: ProfileUpdateRequest,
    authorization: Annotated[str | None, Header()] = None,
) -> ProfileResponse:
    """Set the cook's display name.

    Blank clears it, which returns the account to showing whatever the
    provider supplied at sign-in — or nothing, for a guest. There is no
    separate delete for a field whose empty state is meaningful.
    """
    claims = access_claims(request, authorization)
    name = _trimmed(body.display_name)
    with database(request) as current_database, current_database.begin():
        user = current_database.get(User, claims.user_id)
        if user is None:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
        user.display_name = name
        return ProfileResponse(
            user_kind=user.kind,
            display_name=user.display_name,
            avatar_url=user.avatar_url,
            created_at=user.created_at,
        )


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
        release_device_binding(current_database, device_id=claims.device_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete("/account", status_code=status.HTTP_204_NO_CONTENT)
def delete_account(
    request: Request,
    body: AccountDeletionRequest,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    decoded = decoded_access_claims(request, authorization)
    receipt = _account_deletion(request).completed(
        user_id=decoded.user_id,
        idempotency_key=body.idempotency_key,
    )
    if receipt is None:
        claims = access_claims(request, authorization)
        try:
            receipt = _account_deletion(request).delete(
                claims=claims,
                refresh_token=body.refresh_token,
                idempotency_key=body.idempotency_key,
            )
        except RefreshTokenInvalid as error:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED) from error
        except AccountDeletionUnavailable as error:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE
            ) from error
    return Response(
        status_code=status.HTTP_204_NO_CONTENT,
        headers={
            "X-Deletion-ID": str(receipt.deletion_id),
            "X-Deletion-Status": receipt.status,
        },
    )
