from typing import Annotated, cast
from uuid import UUID

from fastapi import APIRouter, Header, HTTPException, Query, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import Field, PositiveInt

from ladle.api.dependencies import database
from ladle.api.errors import error_response
from ladle.api.routes.auth import access_claims
from ladle.clock import Clock
from ladle.contracts.common import WireModel
from ladle.contracts.errors import (
    ErrorCode,
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


def _recipes(request: Request) -> RecipeService:
    return cast(RecipeService, request.app.state.recipe_service)


def _sync(request: Request) -> RecipeSyncService:
    return cast(RecipeSyncService, request.app.state.sync_service)


def _clock(request: Request) -> Clock:
    return cast(Clock, request.app.state.clock)


def _conflict_response(request: Request, conflict: SyncConflict) -> JSONResponse:
    current = conflict.current_recipe
    return error_response(
        request,
        code=ErrorCode.SYNC_CONFLICT,
        message="The recipe changed on another device.",
        retryable=False,
        details=SyncConflictDetails(
            current_recipe=current,
            current_revision=current.revision,
        ),
        http_status=status.HTTP_409_CONFLICT,
    )


@router.get("/sync", response_model=SyncPageDTO)
def sync_recipes(
    request: Request,
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[PositiveInt, Query(le=200)] = 100,
    authorization: Annotated[str | None, Header()] = None,
) -> SyncPageDTO:
    claims = access_claims(request, authorization)
    with database(request) as current_database:
        return _sync(request).page(
            current_database,
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
        with database(request) as current_database:
            return _recipes(request).get(
                current_database,
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
        with database(request) as current_database, current_database.begin():
            return _recipes(request).upsert(
                current_database,
                user_id=claims.user_id,
                recipe=body.recipe,
                base_revision=body.base_revision,
            )
    except SyncConflict as conflict:
        return _conflict_response(request, conflict)
    except GuestRecipeLimitReached:
        return error_response(
            request,
            code=ErrorCode.GUEST_RECIPE_LIMIT_REACHED,
            message="Create a free account to save more recipes.",
            retryable=False,
            http_status=status.HTTP_409_CONFLICT,
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
        with database(request) as current_database, current_database.begin():
            _recipes(request).delete(
                current_database,
                user_id=claims.user_id,
                recipe_id=recipe_id,
                base_revision=base_revision,
            )
    except SyncConflict as conflict:
        return _conflict_response(request, conflict)
    except RecipeNotFound as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND) from error
    return Response(status_code=status.HTTP_204_NO_CONTENT)
