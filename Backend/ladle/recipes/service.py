from datetime import datetime, timedelta
from urllib.parse import urlsplit
from uuid import UUID, uuid4, uuid5

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.contracts.recipes import (
    DiscoverPageDTO,
    DiscoverSort,
    RecipeDTO,
    RecipeImageDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.db.models import (
    ExtractionCache,
    Recipe,
    RecipeChange,
    RecipeImage,
    SourceVideo,
)
from ladle.recipes.limits import ensure_recipe_capacity
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.template_clone import RecipeTemplate
from ladle.sync.sequence import allocate_sequence


class RecipeNotFound(Exception):
    pass


class InvalidManualRecipe(Exception):
    pass


class DiscoverRecipeUnavailable(Exception):
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
        discover_seen_window: timedelta = timedelta(hours=24),
    ) -> None:
        self._clock = clock
        self._repository = repository or RecipeRepository()
        self._discover_seen_window = discover_seen_window

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
        cursor: int = 0,
        query: str | None = None,
        sort: DiscoverSort = DiscoverSort.POPULAR,
        max_total_minutes: int | None = None,
        seen_before: datetime | None = None,
    ) -> DiscoverPageDTO:
        """One page, with the seen bucket and the impression write together.

        `seen_before` governs both halves deliberately: a caller that does not
        pin a paging session is not building a feed, so it neither demotes nor
        records. That is what keeps the two shelves ranked purely on their own
        criteria and Watch's pages deterministic, while the Discover list —
        the only caller that sends it — turns over between sessions.
        """
        now = self._clock.now()
        page = self._repository.discover(
            database,
            user_id=user_id,
            limit=limit,
            cursor=cursor,
            query=query,
            sort=sort,
            max_total_minutes=max_total_minutes,
            seen_before=seen_before,
            seen_since=(
                None if seen_before is None else now - self._discover_seen_window
            ),
        )
        if seen_before is not None:
            # What was served, not what was ranked: a source dropped for a
            # stale cache never reached the cook and must not be demoted for
            # them next time.
            self._repository.record_discover_impressions(
                database,
                user_id=user_id,
                source_video_ids=[item.source_id for item in page.items],
                seen_at=self._impression_stamp(now, seen_before),
            )
        return page

    def _impression_stamp(self, now: datetime, seen_before: datetime) -> datetime:
        """Never earlier than the pin, and never far beyond it.

        The pin comes from the device and the stamp from the server, so a
        phone whose clock runs a few seconds fast would otherwise write
        impressions that are *older* than its own session — and page 2 would
        demote what page 1 just served, which is the repeat-and-skip the pin
        exists to prevent. Stamping at least the pin puts both in one frame.

        The upper bound is for the clock that is not a few seconds out: an
        unbounded pin is client-controlled input that could park a row years
        ahead of the retention sweep. Past a window's worth of skew the pin
        degrades instead, which is the right way round.
        """
        return min(max(now, seen_before), now + self._discover_seen_window)

    def discover_detail(
        self,
        database: Session,
        *,
        source_video_id: UUID,
    ) -> RecipeDTO:
        source = database.get(SourceVideo, source_video_id)
        if source is None:
            raise DiscoverRecipeUnavailable
        cache_entry = self._current_discover_cache(database, source)
        if cache_entry is None:
            raise DiscoverRecipeUnavailable
        template = self._ready_discover_template(cache_entry)
        preview = template.instantiate(
            recipe_id=source_video_id,
            now=self._clock.now(),
        )
        image_url = self._repository.extraction_thumbnail_url(cache_entry)
        if image_url is None:
            return preview
        return preview.model_copy(
            update={
                "images": [
                    RecipeImageDTO(
                        id=uuid5(source_video_id, "discover-thumbnail"),
                        remote_url=image_url,
                    )
                ]
            }
        )

    def save_discovered(
        self,
        database: Session,
        *,
        user_id: UUID,
        source_video_id: UUID,
    ) -> RecipeDTO:
        source = database.scalar(
            select(SourceVideo)
            .where(SourceVideo.id == source_video_id)
            .with_for_update()
        )
        if source is None:
            raise DiscoverRecipeUnavailable

        existing = database.scalar(
            select(Recipe)
            .where(
                Recipe.user_id == user_id,
                Recipe.source_video_id == source_video_id,
                Recipe.deleted_at.is_(None),
            )
            .order_by(Recipe.updated_at.desc(), Recipe.id)
            .limit(1)
        )
        if existing is not None:
            return self._repository.to_dto(database, existing)

        cache_entry = self._current_discover_cache(database, source)
        if cache_entry is None:
            raise DiscoverRecipeUnavailable

        template = self._ready_discover_template(cache_entry)
        ensure_recipe_capacity(database, user_id)
        now = self._clock.now()
        recipe = template.instantiate(recipe_id=uuid4(), now=now)
        stored = self._repository.insert(
            database,
            user_id=user_id,
            recipe=recipe,
            created_at=now,
        )
        stored.source_video_id = source_video_id
        stored.source_cache_id = cache_entry.id
        if (
            cache_entry.thumbnail_object_key is not None
            or cache_entry.thumbnail_remote_url is not None
        ):
            database.add(
                RecipeImage(
                    id=uuid4(),
                    recipe_id=stored.id,
                    object_key=cache_entry.thumbnail_object_key,
                    remote_url=cache_entry.thumbnail_remote_url,
                    order_index=0,
                )
            )
        self._record_change(
            database,
            user_id=user_id,
            recipe_id=stored.id,
            kind="upsert",
            revision=stored.revision,
            changed_at=now,
        )
        database.flush()
        return self._repository.to_dto(database, stored)

    def _current_discover_cache(
        self,
        database: Session,
        source: SourceVideo,
    ) -> ExtractionCache | None:
        return database.scalar(
            select(ExtractionCache)
            .where(
                ExtractionCache.source_video_id == source.id,
                ExtractionCache.source_revision == source.source_revision,
                ExtractionCache.review_status == RecipeReviewStatus.READY.value,
                ExtractionCache.invalidated_at.is_(None),
            )
            .order_by(ExtractionCache.created_at.desc(), ExtractionCache.id)
            .limit(1)
        )

    def _ready_discover_template(
        self,
        cache_entry: ExtractionCache,
    ) -> RecipeTemplate:
        template = RecipeTemplate.model_validate(cache_entry.template_json)
        if template.review_status != RecipeReviewStatus.READY:
            raise DiscoverRecipeUnavailable
        return template

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
            for_update=True,
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
            for_update=True,
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
