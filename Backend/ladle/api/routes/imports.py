from typing import Annotated, cast
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import AnyHttpUrl, Field

from ladle.api.dependencies import database
from ladle.api.errors import error_response
from ladle.api.routes.auth import access_claims
from ladle.contracts.common import WireModel, WireUUID
from ladle.contracts.errors import DuplicateRecipeDetails, ErrorCode
from ladle.contracts.imports import ImportJobResponse
from ladle.imports.admission import (
    AdmissionService,
    CurrentRecipeUnavailable,
    DuplicateRecipe,
    ImportJobNotFound,
)
from ladle.imports.dispatcher import ImportDispatcher
from ladle.imports.source_identity import InvalidSourceURL, UnsupportedSource
from ladle.imports.transitions import ImportRetryService, ImportRetryUnavailable
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


class RetryImportRequest(WireModel):
    correction_notes: str | None = Field(default=None, max_length=10_000)
    pasted_text: str | None = Field(default=None, max_length=200_000)


def _admission(request: Request) -> AdmissionService:
    return cast(AdmissionService, request.app.state.admission_service)


def _dispatcher(request: Request) -> ImportDispatcher:
    return cast(ImportDispatcher, request.app.state.import_dispatcher)


def _retry_service(request: Request) -> ImportRetryService:
    return cast(ImportRetryService, request.app.state.import_retry_service)


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


@router.post(
    "",
    response_model=ImportJobResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def submit_import(
    body: ImportSubmissionRequest,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> ImportJobResponse | JSONResponse:
    claims = access_claims(request, authorization)
    try:
        with database(request) as current_database, current_database.begin():
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
            response = admitted.response
    except GuestRecipeLimitReached:
        return _error(
            request,
            code=ErrorCode.GUEST_RECIPE_LIMIT_REACHED,
            message="Create a free account to save more recipes.",
            http_status=status.HTTP_409_CONFLICT,
        )
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

    if admitted.should_dispatch:
        _dispatcher(request).enqueue(admitted.job_id)
    return response


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
            return _admission(request).response(job)
    except ImportJobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error


@router.post(
    "/{job_id}/retry",
    response_model=ImportJobResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
def retry_import(
    job_id: UUID,
    body: RetryImportRequest,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> ImportJobResponse:
    claims = access_claims(request, authorization)
    try:
        with database(request) as current_database, current_database.begin():
            job = _retry_service(request).retry(
                current_database,
                user_id=claims.user_id,
                job_id=job_id,
                correction_notes=body.correction_notes,
                pasted_text=body.pasted_text,
            )
            response = _admission(request).response(job)
    except ImportRetryUnavailable as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT) from error
    _dispatcher(request).enqueue(job_id)
    return response
