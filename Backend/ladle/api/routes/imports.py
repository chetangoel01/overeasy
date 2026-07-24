from typing import Annotated, cast
from uuid import UUID, uuid4

from fastapi import APIRouter, Header, HTTPException, Request, status
from fastapi.responses import JSONResponse
from pydantic import AnyHttpUrl
from sqlalchemy.orm import Session

from ladle.api.routes.auth import access_claims
from ladle.contracts.common import WireModel, WireUUID
from ladle.contracts.errors import (
    DuplicateRecipeDetails,
    ErrorCode,
    ErrorDTO,
    ErrorEnvelope,
)
from ladle.contracts.imports import ImportJobResponse
from ladle.imports.admission import (
    AdmissionService,
    DuplicateRecipe,
    ImportJobNotFound,
)
from ladle.imports.dispatcher import ImportDispatcher
from ladle.imports.source_identity import InvalidSourceURL, UnsupportedSource
from ladle.recipes.limits import GuestRecipeLimitReached

router = APIRouter(prefix="/v1/imports", tags=["imports"])


class ImportSubmissionRequest(WireModel):
    job_id: WireUUID
    source_url: AnyHttpUrl
    allow_duplicate: bool = False
    idempotency_key: str | None = None


def _database(request: Request) -> Session:
    return cast(Session, request.app.state.session_factory())


def _admission(request: Request) -> AdmissionService:
    return cast(AdmissionService, request.app.state.admission_service)


def _dispatcher(request: Request) -> ImportDispatcher:
    return cast(ImportDispatcher, request.app.state.import_dispatcher)


def _error(
    *,
    code: ErrorCode,
    message: str,
    retryable: bool = False,
    details: DuplicateRecipeDetails | None = None,
    http_status: int,
) -> JSONResponse:
    envelope = ErrorEnvelope(
        error=ErrorDTO(
            code=code,
            message=message,
            retryable=retryable,
            request_id=uuid4(),
            details=details,
        )
    )
    return JSONResponse(
        status_code=http_status,
        content=envelope.model_dump(mode="json", by_alias=True),
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
        with _database(request) as database, database.begin():
            admitted = _admission(request).admit(
                database,
                job_id=body.job_id,
                user_id=claims.user_id,
                source_url=str(body.source_url),
                allow_duplicate=body.allow_duplicate,
                idempotency_key=body.idempotency_key or str(body.job_id),
            )
            response = admitted.response
    except GuestRecipeLimitReached:
        return _error(
            code=ErrorCode.GUEST_RECIPE_LIMIT_REACHED,
            message="Create a free account to save more recipes.",
            http_status=status.HTTP_409_CONFLICT,
        )
    except DuplicateRecipe as duplicate:
        return _error(
            code=ErrorCode.DUPLICATE_RECIPE,
            message="This recipe is already in your library.",
            details=DuplicateRecipeDetails(
                existing_recipe_id=duplicate.existing_recipe_id
            ),
            http_status=status.HTTP_409_CONFLICT,
        )
    except InvalidSourceURL:
        return _error(
            code=ErrorCode.INVALID_URL,
            message="The video URL is invalid.",
            http_status=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )
    except UnsupportedSource:
        return _error(
            code=ErrorCode.UNSUPPORTED_SOURCE,
            message="That video source is not supported.",
            http_status=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )

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
        with _database(request) as database:
            job = _admission(request).get(
                database,
                user_id=claims.user_id,
                job_id=job_id,
            )
            return _admission(request).response(job)
    except ImportJobNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
