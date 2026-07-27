from typing import Protocol

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.db.models import (
    ExtractionCache,
    Recipe,
    RecipeImage,
    SourceVideo,
)


class ThumbnailFetcher(Protocol):
    def fetch(
        self,
        source: SourceVideoDescriptor,
        *,
        candidate_url: str | None = None,
    ) -> str | None: ...


class ThumbnailBackfillService:
    """Move legacy provider thumbnails into private object storage."""

    def __init__(self, *, fetcher: ThumbnailFetcher) -> None:
        self._fetcher = fetcher

    def run(self, database: Session) -> int:
        entries = database.execute(
            select(ExtractionCache, SourceVideo)
            .join(
                SourceVideo,
                SourceVideo.id == ExtractionCache.source_video_id,
            )
            .where(ExtractionCache.thumbnail_remote_url.is_not(None))
            .order_by(ExtractionCache.created_at, ExtractionCache.id)
        ).all()
        converted = 0
        for cache, stored_source in entries:
            remote_url = cache.thumbnail_remote_url
            key = self._fetcher.fetch(
                SourceVideoDescriptor.from_stored(stored_source),
                candidate_url=remote_url,
            )
            if key is None:
                continue
            cache.thumbnail_object_key = key
            cache.thumbnail_remote_url = None
            images = database.scalars(
                select(RecipeImage)
                .join(Recipe, Recipe.id == RecipeImage.recipe_id)
                .where(
                    Recipe.source_cache_id == cache.id,
                    RecipeImage.remote_url == remote_url,
                )
            )
            for image in images:
                image.object_key = key
                image.remote_url = None
            converted += 1
        return converted
