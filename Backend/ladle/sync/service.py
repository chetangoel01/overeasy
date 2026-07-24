from uuid import UUID

from pydantic import PositiveInt
from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.contracts.recipes import (
    RecipeChangeDTO,
    SyncChangeKind,
    SyncPageDTO,
)
from ladle.db.models import RecipeChange
from ladle.observability.metrics import MetricsRegistry
from ladle.recipes.repository import RecipeRepository


class RecipeSyncService:
    def __init__(
        self,
        repository: RecipeRepository | None = None,
        *,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._repository = repository or RecipeRepository()
        self._metrics = metrics

    def page(
        self,
        database: Session,
        *,
        user_id: UUID,
        cursor: int,
        limit: PositiveInt,
    ) -> SyncPageDTO:
        rows = list(
            database.scalars(
                select(RecipeChange)
                .where(
                    RecipeChange.user_id == user_id,
                    RecipeChange.sequence > cursor,
                )
                .order_by(RecipeChange.sequence)
                .limit(int(limit) + 1)
            )
        )
        has_more = len(rows) > int(limit)
        visible = rows[: int(limit)]
        changes: list[RecipeChangeDTO] = []
        for row in visible:
            stored = self._repository.find(
                database,
                user_id=user_id,
                recipe_id=row.recipe_id,
                include_deleted=True,
            )
            if (
                stored is not None
                and stored.deleted_at is None
                and row.kind == "upsert"
            ):
                recipe = self._repository.to_dto(database, stored)
                kind = SyncChangeKind.UPSERT
                revision = recipe.revision
            else:
                recipe = None
                kind = SyncChangeKind.DELETE
                revision = (
                    stored.revision if stored is not None else row.recipe_revision
                )
            changes.append(
                RecipeChangeDTO(
                    sequence=row.sequence,
                    recipe_id=row.recipe_id,
                    kind=kind,
                    recipe_revision=revision,
                    changed_at=row.changed_at,
                    recipe=recipe,
                )
            )

        page = SyncPageDTO(
            changes=changes,
            next_cursor=visible[-1].sequence if visible else cursor,
            has_more=has_more,
        )
        if self._metrics is not None:
            self._metrics.record_sync("success")
        return page
