from uuid import UUID

from pydantic import PositiveInt
from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.contracts.recipes import (
    RecipeChangeDTO,
    SyncChangeKind,
    SyncPageDTO,
)
from ladle.db.models import RecipeChange, UserSyncState
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
        state = database.get(UserSyncState, user_id)
        if (
            cursor > 0
            and state is not None
            and cursor < state.minimum_retained_sequence
        ):
            if self._metrics is not None:
                self._metrics.record_sync("reset")
            raise SyncCursorExpired(state.minimum_retained_sequence)
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
        # One recipe read and one materialisation for the whole page: the
        # per-row find() + to_dto() this replaces cost ~9 queries per change,
        # so a 100-change page fanned out to ~900 statements on one pooled
        # connection.
        stored_by_id = self._repository.find_many(
            database,
            user_id=user_id,
            recipe_ids={row.recipe_id for row in visible},
        )
        upsert_ids = {row.recipe_id for row in visible if row.kind == "upsert"}
        recipes = self._repository.to_dtos(
            database,
            [
                stored
                for recipe_id, stored in stored_by_id.items()
                if recipe_id in upsert_ids and stored.deleted_at is None
            ],
        )
        changes: list[RecipeChangeDTO] = []
        for row in visible:
            recipe = recipes.get(row.recipe_id) if row.kind == "upsert" else None
            if recipe is not None:
                kind = SyncChangeKind.UPSERT
                revision = recipe.revision
            else:
                stored = stored_by_id.get(row.recipe_id)
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


class SyncCursorExpired(Exception):
    def __init__(self, minimum_retained_sequence: int) -> None:
        super().__init__("sync cursor predates retained history")
        self.minimum_retained_sequence = minimum_retained_sequence
