from datetime import datetime
from urllib.parse import urlsplit
from uuid import UUID

from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.contracts.recipes import DiscoverPageDTO, RecipeDTO, RecipeSource
from ladle.db.models import RecipeChange
from ladle.recipes.limits import ensure_recipe_capacity
from ladle.recipes.repository import RecipeRepository
from ladle.sync.sequence import allocate_sequence


class RecipeNotFound(Exception):
    pass


class InvalidManualRecipe(Exception):
    pass


class SyncConflict(Exception):
    def __init__(self, current_recipe: RecipeDTO) -> None:
        super().__init__("recipe revision is stale")
        self.current_recipe = current_recipe


class RecipeService:
    def __init__(
        self,
        *,
        clock: Clock,
        repository: RecipeRepository | None = None,
    ) -> None:
        self._clock = clock
        self._repository = repository or RecipeRepository()

    def get(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_id: UUID,
    ) -> RecipeDTO:
        stored = self._repository.find(
            database,
            user_id=user_id,
            recipe_id=recipe_id,
        )
        if stored is None:
            raise RecipeNotFound
        return self._repository.to_dto(database, stored)

    def discover(
        self,
        database: Session,
        *,
        user_id: UUID,
        limit: int,
    ) -> DiscoverPageDTO:
        return self._repository.discover(
            database,
            user_id=user_id,
            limit=limit,
        )

    def upsert(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe: RecipeDTO,
        base_revision: int,
    ) -> RecipeDTO:
        stored = self._repository.find(
            database,
            user_id=user_id,
            recipe_id=recipe.id,
            include_deleted=True,
        )
        if stored is not None:
            current = self._repository.to_dto(database, stored)
            if base_revision == 0 and stored.deleted_at is None:
                return current
            if stored.deleted_at is not None or stored.revision != base_revision:
                raise SyncConflict(current)

            updated = self._repository.update(
                database,
                stored=stored,
                recipe=recipe,
                updated_at=self._clock.now(),
            )
            self._record_change(
                database,
                user_id=user_id,
                recipe_id=updated.id,
                kind="upsert",
                revision=updated.revision,
                changed_at=updated.updated_at,
            )
            database.flush()
            return self._repository.to_dto(database, updated)

        if base_revision != 0:
            raise RecipeNotFound
        self._validate_manual_recipe(recipe)
        ensure_recipe_capacity(database, user_id)
        now = self._clock.now()
        created = self._repository.insert(
            database,
            user_id=user_id,
            recipe=recipe,
            created_at=now,
        )
        self._record_change(
            database,
            user_id=user_id,
            recipe_id=created.id,
            kind="upsert",
            revision=created.revision,
            changed_at=now,
        )
        database.flush()
        return self._repository.to_dto(database, created)

    def delete(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_id: UUID,
        base_revision: int,
    ) -> None:
        stored = self._repository.find(
            database,
            user_id=user_id,
            recipe_id=recipe_id,
            include_deleted=True,
        )
        if stored is None:
            raise RecipeNotFound
        current = self._repository.to_dto(database, stored)
        if stored.deleted_at is not None or stored.revision != base_revision:
            raise SyncConflict(current)
        now = self._clock.now()
        stored.deleted_at = now
        stored.updated_at = now
        stored.revision += 1
        self._record_change(
            database,
            user_id=user_id,
            recipe_id=stored.id,
            kind="delete",
            revision=stored.revision,
            changed_at=now,
        )

    def _record_change(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_id: UUID,
        kind: str,
        revision: int,
        changed_at: datetime,
    ) -> None:
        database.add(
            RecipeChange(
                user_id=user_id,
                sequence=allocate_sequence(database, user_id),
                recipe_id=recipe_id,
                kind=kind,
                recipe_revision=revision,
                changed_at=changed_at,
            )
        )

    def _validate_manual_recipe(self, recipe: RecipeDTO) -> None:
        parsed = urlsplit(str(recipe.original_url))
        if (
            recipe.source != RecipeSource.OTHER
            or parsed.scheme != "https"
            or parsed.hostname != "manual.ladle.local"
            or parsed.path != f"/{recipe.id}"
            or parsed.query
            or parsed.fragment
        ):
            raise InvalidManualRecipe
