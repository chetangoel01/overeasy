from typing import Annotated, cast
from uuid import UUID, uuid4

from fastapi import APIRouter, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import Field, PositiveInt
from sqlalchemy.orm import Session

from ladle.api.routes.auth import access_claims
from ladle.clock import Clock
from ladle.contracts.common import WireModel
from ladle.contracts.errors import (
    ErrorCode,
    ErrorDTO,
    ErrorEnvelope,
    SyncConflictDetails,
)
from ladle.contracts.recipes import RecipeDTO, SyncPageDTO
from ladle.recipes.limits import GuestRecipeLimitReached
from ladle.recipes.service import (
    InvalidManualRecipe,
    RecipeNotFound,
    RecipeService,
    SyncConflict,
)
from ladle.sync.service import RecipeSyncService

router = APIRouter(prefix="/v1/recipes", tags=["recipes"])


class RecipeMutationRequest(WireModel):
    base_revision: int = Field(ge=0)
    recipe: RecipeDTO


def _database(request: Request) -> Session:
    return cast(Session, request.app.state.session_factory())


def _recipes(request: Request) -> RecipeService:
    return cast(RecipeService, request.app.state.recipe_service)


def _sync(request: Request) -> RecipeSyncService:
    return cast(RecipeSyncService, request.app.state.sync_service)


def _clock(request: Request) -> Clock:
    return cast(Clock, request.app.state.clock)


def _conflict_response(conflict: SyncConflict) -> JSONResponse:
    current = conflict.current_recipe
    envelope = ErrorEnvelope(
        error=ErrorDTO(
            code=ErrorCode.SYNC_CONFLICT,
            message="The recipe changed on another device.",
            retryable=False,
            request_id=uuid4(),
            details=SyncConflictDetails(
                current_recipe=current,
                current_revision=current.revision,
            ),
        )
    )
    return JSONResponse(
        status_code=status.HTTP_409_CONFLICT,
        content=envelope.model_dump(mode="json", by_alias=True),
    )


@router.get("/sync", response_model=SyncPageDTO)
def sync_recipes(
    request: Request,
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[PositiveInt, Query(le=200)] = 100,
    authorization: Annotated[str | None, Header()] = None,
) -> SyncPageDTO:
    claims = access_claims(request, authorization)
    with _database(request) as database:
        return _sync(request).page(
            database,
            user_id=claims.user_id,
            cursor=cursor,
            limit=limit,
        )


@router.get("/{recipe_id}", response_model=RecipeDTO)
def get_recipe(
    recipe_id: UUID,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> RecipeDTO:
    claims = access_claims(request, authorization)
    try:
        with _database(request) as database:
            return _recipes(request).get(
                database,
                user_id=claims.user_id,
                recipe_id=recipe_id,
            )
    except RecipeNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error


@router.put("/{recipe_id}", response_model=RecipeDTO)
def put_recipe(
    recipe_id: UUID,
    body: RecipeMutationRequest,
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
) -> RecipeDTO | JSONResponse:
    claims = access_claims(request, authorization)
    if body.recipe.id != recipe_id:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
            detail="path and recipe IDs differ",
        )
    try:
        with _database(request) as database, database.begin():
            return _recipes(request).upsert(
                database,
                user_id=claims.user_id,
                recipe=body.recipe,
                base_revision=body.base_revision,
            )
    except SyncConflict as conflict:
        return _conflict_response(conflict)
    except GuestRecipeLimitReached:
        envelope = ErrorEnvelope(
            error=ErrorDTO(
                code=ErrorCode.GUEST_RECIPE_LIMIT_REACHED,
                message="Create a free account to save more recipes.",
                retryable=False,
                request_id=uuid4(),
                details=None,
            )
        )
        return JSONResponse(
            status_code=status.HTTP_409_CONFLICT,
            content=envelope.model_dump(mode="json", by_alias=True),
        )
    except InvalidManualRecipe as error:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_CONTENT
        ) from error
    except RecipeNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error


@router.delete(
    "/{recipe_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
)
def delete_recipe(
    recipe_id: UUID,
    request: Request,
    base_revision: Annotated[int, Query(alias="baseRevision", ge=1)],
    authorization: Annotated[str | None, Header()] = None,
) -> Response:
    claims = access_claims(request, authorization)
    try:
        with _database(request) as database, database.begin():
            _recipes(request).delete(
                database,
                user_id=claims.user_id,
                recipe_id=recipe_id,
                base_revision=base_revision,
            )
    except SyncConflict as conflict:
        return _conflict_response(conflict)
    except RecipeNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    return Response(status_code=status.HTTP_204_NO_CONTENT)
