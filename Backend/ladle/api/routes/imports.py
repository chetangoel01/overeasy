import hashlib
from typing import Annotated, Literal, cast
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse, Response
from pydantic import AnyHttpUrl, Field, ValidationError, field_validator
from sqlalchemy.orm import Session

from ladle.api.dependencies import database
from ladle.api.errors import error_response
from ladle.api.rate_limits import RateLimitPolicies, RateLimitService
from ladle.api.routes.auth import access_claims
from ladle.auth.attestation import (
    AppAttestEvidence,
    AppAttestPurpose,
    AttestationRejected,
    AttestationService,
)
from ladle.auth.tokens import AccessClaims
from ladle.contracts.common import WireModel, WireUUID
from ladle.contracts.errors import DuplicateRecipeDetails, ErrorCode
from ladle.contracts.imports import ImportJobResponse
from ladle.crypto.private_text import validate_private_text
from ladle.db.models import Device
from ladle.imports.admission import (
    AdmissionService,
    CurrentRecipeUnavailable,
    DuplicateRecipe,
    ImportJobNotFound,
)
from ladle.imports.dispatcher import ImportDispatcher
from ladle.imports.outbox import DispatchOutboxService
from ladle.imports.quotas import ImportQuotaExceeded
from ladle.imports.source_identity import InvalidSourceURL, UnsupportedSource
from ladle.imports.transitions import (
    ImportCancellationService,
    ImportCancellationUnavailable,
    ImportRetryService,
    ImportRetryUnavailable,
)
from ladle.recipes.limits import GuestRecipeLimitReached

router = APIRouter(prefix="/v1/imports", tags=["imports"])


class ImportSubmissionRequest(WireModel):
    job_id: WireUUID
    source_url: AnyHttpUrl
    allow_duplicate: bool = False
    idempotency_key: str | None = None
    current_recipe_id: WireUUID | None = None
    correction_notes: str | None = Field(default=None, max_length=10_000)
    pasted_text: str | None = Field(default=None, max_length=200_000)

    @field_validator("correction_notes", "pasted_text")
    @classmethod
    def validate_private_text_bytes(cls, value: str | None) -> str | None:
        return validate_private_text(value) if value is not None else None


class RetryImportRequest(WireModel):
    correction_notes: str | None = Field(default=None, max_length=10_000)
    pasted_text: str | None = Field(default=None, max_length=200_000)

    @field_validator("correction_notes", "pasted_text")
    @classmethod
    def validate_private_text_bytes(cls, value: str | None) -> str | None:
        return validate_private_text(value) if value is not None else None


async def _request_body(request: Request) -> bytes:
    """Read the raw request body (for the App Attest hash) on the event loop.

    This is the only genuinely asynchronous step these endpoints need. The
    handlers themselves are `def` like every other route in the app, so
    their blocking I/O — sync SQLAlchemy sessions, the rate-limit Redis
    call, the outbox row lock and broker publish — runs in the anyio
    threadpool instead of stalling the event loop for every other request.
    """
    return await request.body()


def _admission(request: Request) -> AdmissionService:
    return cast(AdmissionService, request.app.state.admission_service)


def _dispatcher(request: Request) -> ImportDispatcher:
    return cast(ImportDispatcher, request.app.state.import_dispatcher)


def _dispatch_outbox(request: Request) -> DispatchOutboxService:
    return cast(DispatchOutboxService, request.app.state.dispatch_outbox)


def _retry_service(request: Request) -> ImportRetryService:
    return cast(ImportRetryService, request.app.state.import_retry_service)


def _cancellation_service(request: Request) -> ImportCancellationService:
    return cast(
        ImportCancellationService,
        request.app.state.import_cancellation_service,
    )


def _attestation(request: Request) -> AttestationService:
    return cast(AttestationService, request.app.state.attestation)


def _rate_limits(request: Request) -> RateLimitService:
    return cast(RateLimitService, request.app.state.rate_limits)


def _rate_limit_policies(request: Request) -> RateLimitPolicies:
    return cast(RateLimitPolicies, request.app.state.rate_limit_policies)


def _installation_id(request: Request, claims: AccessClaims) -> str:
    with database(request) as current_database:
        device = current_database.get(Device, claims.device_id)
        if device is None or device.user_id != claims.user_id:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED)
        return device.installation_id


def _enforce_import_rate_limit(
    request: Request,
    *,
    operation: Literal["submit", "retry"],
    claims: AccessClaims,
) -> None:
    limits = _rate_limits(request)
    limits.enforce(
        _rate_limit_policies(request).import_request(
            operation,
            limits.client_ip(request),
            _installation_id(request, claims),
            str(claims.user_id),
        )
    )


def _assertion_evidence(request: Request) -> AppAttestEvidence | None:
    values = {
        "kind": request.headers.get("x-app-attest-kind"),
        "keyID": request.headers.get("x-app-attest-key-id"),
        "challengeID": request.headers.get("x-app-attest-challenge-id"),
        "challenge": request.headers.get("x-app-attest-challenge"),
        "assertion": request.headers.get("x-app-attest-assertion"),
        "clientData": request.headers.get("x-app-attest-client-data"),
    }
    if all(value is None for value in values.values()):
        return None
    if any(value is None for value in values.values()):
        raise AttestationRejected("App Attest assertion headers are incomplete")
    try:
        return AppAttestEvidence.model_validate(values)
    except ValidationError as error:
        raise AttestationRejected("App Attest assertion headers are invalid") from error


def _verify_sensitive_request(
    request: Request,
    current_database: Session,
    *,
    claims: AccessClaims,
    purpose: AppAttestPurpose,
    body_sha256: str,
) -> AttestationRejected | None:
    try:
        device = current_database.get(Device, claims.device_id)
        if device is None or device.user_id != claims.user_id:
            raise AttestationRejected("authenticated installation is unavailable")
        _attestation(request).verify(
            current_database,
            installation_id=device.installation_id,
            purpose=purpose,
            method=request.method,
            path=request.url.path,
            body_sha256=body_sha256,
            evidence=_assertion_evidence(request),
        )
    except AttestationRejected as error:
        return error
    return None


def _error(
    request: Request,
    *,
    code: ErrorCode,
    message: str,
    retryable: bool = False,
    details: DuplicateRecipeDetails | None = None,
    http_status: int,
) -> JSONResponse:
    return error_response(
        request,
        code=code,
        message=message,
        retryable=retryable,
        details=details,
        http_status=http_status,
    )


def _quota_error(
    request: Request,
    error: ImportQuotaExceeded,
) -> JSONResponse:
    response = _error(
        request,
        code=ErrorCode.QUOTA_EXCEEDED,
        message=f"Your {error.period} import quota has been reached.",
        retryable=True,
        http_status=status.HTTP_429_TOO_MANY_REQUESTS,
    )
    response.headers["Retry-After"] = str(error.retry_after_seconds)
    return response


@router.post(
    "",
    response_model=ImportJobResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def submit_import(
    body: ImportSubmissionRequest,
    request: Request,
    raw_body: Annotated[bytes, Depends(_request_body)],
    authorization: Annotated[str | None, Header()] = None,
) -> ImportJobResponse | JSONResponse:
    claims = access_claims(request, authorization)
    _enforce_import_rate_limit(request, operation="submit", claims=claims)
    body_sha256 = hashlib.sha256(raw_body).hexdigest()
    rejection: AttestationRejected | None = None
    admitted = None
    try:
        with database(request) as current_database, current_database.begin():
            rejection = _verify_sensitive_request(
                request,
                current_database,
                claims=claims,
                purpose=AppAttestPurpose.IMPORT_SUBMISSION,
                body_sha256=body_sha256,
            )
            if rejection is None:
                admitted = _admission(request).admit(
                    current_database,
                    job_id=body.job_id,
                    user_id=claims.user_id,
                    source_url=str(body.source_url),
                    allow_duplicate=body.allow_duplicate,
                    idempotency_key=body.idempotency_key or str(body.job_id),
                    current_recipe_id=body.current_recipe_id,
                    correction_notes=body.correction_notes,
                    pasted_text=body.pasted_text,
                )
    except GuestRecipeLimitReached:
        return _error(
            request,
            code=ErrorCode.GUEST_RECIPE_LIMIT_REACHED,
            message="Create a free account to save more recipes.",
            http_status=status.HTTP_409_CONFLICT,
        )
    except ImportQuotaExceeded as error:
        return _quota_error(request, error)
    except DuplicateRecipe as duplicate:
        return _error(
            request,
            code=ErrorCode.DUPLICATE_RECIPE,
            message="This recipe is already in your library.",
            details=DuplicateRecipeDetails(
                existing_recipe_id=duplicate.existing_recipe_id
            ),
            http_status=status.HTTP_409_CONFLICT,
        )
    except InvalidSourceURL:
        return _error(
            request,
            code=ErrorCode.INVALID_URL,
            message="The video URL is invalid.",
            http_status=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    except UnsupportedSource:
        return _error(
            request,
            code=ErrorCode.UNSUPPORTED_SOURCE,
            message="That video source is not supported.",
            http_status=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    except CurrentRecipeUnavailable as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error

    if rejection is not None or admitted is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN) from rejection
    if admitted.should_dispatch:
        _dispatch_outbox(request).dispatch_one(
            _dispatcher(request),
            admitted.job_id,
        )
    return admitted.response


@router.get("/{job_id}", response_model=ImportJobResponse)
def get_import(
    job_id: UUID,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> ImportJobResponse:
    claims = access_claims(request, authorization)
    try:
        with database(request) as current_database:
            job = _admission(request).get(
                current_database,
                user_id=claims.user_id,
                job_id=job_id,
            )
            if job.status == "cancelled":
                raise ImportJobNotFound
            return _admission(request).response(job)
    except ImportJobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error


@router.delete(
    "/{job_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
def cancel_import(
    job_id: UUID,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    claims = access_claims(request, authorization)
    try:
        with database(request) as current_database, current_database.begin():
            _cancellation_service(request).cancel(
                current_database,
                user_id=claims.user_id,
                job_id=job_id,
            )
    except ImportCancellationUnavailable as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT) from error
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/{job_id}/retry",
    response_model=ImportJobResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def retry_import(
    job_id: UUID,
    body: RetryImportRequest,
    request: Request,
    raw_body: Annotated[bytes, Depends(_request_body)],
    authorization: Annotated[str | None, Header()] = None,
) -> ImportJobResponse | JSONResponse:
    claims = access_claims(request, authorization)
    _enforce_import_rate_limit(request, operation="retry", claims=claims)
    body_sha256 = hashlib.sha256(raw_body).hexdigest()
    rejection: AttestationRejected | None = None
    job = None
    try:
        with database(request) as current_database, current_database.begin():
            rejection = _verify_sensitive_request(
                request,
                current_database,
                claims=claims,
                purpose=AppAttestPurpose.IMPORT_RETRY,
                body_sha256=body_sha256,
            )
            if rejection is None:
                job = _retry_service(request).retry(
                    current_database,
                    user_id=claims.user_id,
                    job_id=job_id,
                    correction_notes=body.correction_notes,
                    pasted_text=body.pasted_text,
                )
    except ImportRetryUnavailable as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT) from error
    except ImportQuotaExceeded as error:
        return _quota_error(request, error)
    if rejection is not None or job is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN) from rejection
    _dispatch_outbox(request).dispatch_one(_dispatcher(request), job_id)
    return _admission(request).response(job)
