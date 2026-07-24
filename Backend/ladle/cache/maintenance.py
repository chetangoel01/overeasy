from typing import Protocol
from uuid import UUID

from sqlalchemy import exists, select, update
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ExtractionCache, Recipe, RecipeImage, SourceVideo


class ObjectCleaner(Protocol):
    def delete(self, key: str) -> None: ...


class CacheMaintenanceService:
    def __init__(self, *, clock: Clock) -> None:
        self._clock = clock

    def confirm_public(self, database: Session, *, source_video_id: UUID) -> None:
        source = database.execute(
            select(SourceVideo)
            .where(SourceVideo.id == source_video_id)
            .with_for_update()
        ).scalar_one()
        now = self._clock.now()
        source.public_access_confirmed_at = now
        source.checked_at = now

    def mark_private_or_deleted(
        self,
        database: Session,
        *,
        source_video_id: UUID,
    ) -> None:
        source = database.execute(
            select(SourceVideo)
            .where(SourceVideo.id == source_video_id)
            .with_for_update()
        ).scalar_one()
        now = self._clock.now()
        source.public_access_confirmed_at = None
        source.checked_at = now
        database.execute(
            update(ExtractionCache)
            .where(
                ExtractionCache.source_video_id == source_video_id,
                ExtractionCache.invalidated_at.is_(None),
            )
            .values(invalidated_at=now)
        )

    def delete_unreferenced_thumbnails(
        self,
        database: Session,
        *,
        storage: ObjectCleaner,
    ) -> int:
        entries = list(
            database.scalars(
                select(ExtractionCache).where(
                    ExtractionCache.invalidated_at.is_not(None),
                    ExtractionCache.thumbnail_object_key.is_not(None),
                    ~exists(
                        select(Recipe.id).where(
                            Recipe.source_cache_id == ExtractionCache.id
                        )
                    ),
                    ~exists(
                        select(RecipeImage.id).where(
                            RecipeImage.object_key
                            == ExtractionCache.thumbnail_object_key
                        )
                    ),
                )
            )
        )
        for entry in entries:
            if entry.thumbnail_object_key is not None:
                storage.delete(entry.thumbnail_object_key)
                entry.thumbnail_object_key = None
        return len(entries)
