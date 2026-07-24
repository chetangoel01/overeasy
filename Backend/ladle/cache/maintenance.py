from datetime import timedelta
from typing import Protocol
from uuid import UUID, uuid4

from sqlalchemy import exists, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import (
    ExtractionCache,
    NegativeExtractionCache,
    Recipe,
    RecipeImage,
    SourceVideo,
)


class ObjectCleaner(Protocol):
    def delete(self, key: str) -> None: ...


class CacheMaintenanceService:
    def __init__(
        self,
        *,
        clock: Clock,
        negative_ttl: timedelta = timedelta(minutes=15),
    ) -> None:
        self._clock = clock
        self._negative_ttl = negative_ttl

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
        database.execute(
            insert(NegativeExtractionCache)
            .values(
                id=uuid4(),
                source_video_id=source_video_id,
                reason="privateOrDeleted",
                created_at=now,
                expires_at=now + self._negative_ttl,
            )
            .on_conflict_do_update(
                index_elements=[NegativeExtractionCache.source_video_id],
                set_={
                    "reason": "privateOrDeleted",
                    "created_at": now,
                    "expires_at": now + self._negative_ttl,
                },
            )
        )

    def purge_expired_negative_entries(self, database: Session) -> int:
        entries = list(
            database.scalars(
                select(NegativeExtractionCache).where(
                    NegativeExtractionCache.expires_at <= self._clock.now()
                )
            )
        )
        for entry in entries:
            database.delete(entry)
        return len(entries)

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
