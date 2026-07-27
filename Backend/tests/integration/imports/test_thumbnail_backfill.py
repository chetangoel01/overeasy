from datetime import UTC, datetime
from decimal import Decimal

import pytest
from sqlalchemy import select

from alembic import command
from ladle.db.models import (
    ExtractionCache,
    Recipe,
    RecipeImage,
    SourceVideo,
)
from ladle.db.session import build_engine, build_session_factory
from ladle.imports.thumbnail_backfill import ThumbnailBackfillService
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


class RecordingFetcher:
    def __init__(self) -> None:
        self.candidates: list[str | None] = []

    def fetch(self, source: object, *, candidate_url: str | None = None) -> str:
        self.candidates.append(candidate_url)
        return "thumbnails/tiktok-video/durable.webp"


@pytest.mark.integration
def test_backfill_replaces_cached_and_recipe_remote_thumbnail_locations(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    sessions = build_session_factory(build_engine(clean_postgres_url))
    remote_url = "https://p16-sign.tiktokcdn-us.com/expiring.webp"

    with sessions.begin() as database:
        user_id = seed_user(database)
        source = SourceVideo(
            platform="tiktok",
            platform_video_id="tiktok-video",
            canonical_url="https://www.tiktok.com/@cook/video/tiktok-video",
            source_revision="1",
            source_metadata={},
        )
        database.add(source)
        database.flush()
        cache = ExtractionCache(
            source_video_id=source.id,
            source_revision="1",
            contract_version="v1",
            prompt_version="recipe-v1",
            model_id="model",
            template_json={},
            review_status="ready",
            thumbnail_remote_url=remote_url,
        )
        database.add(cache)
        database.flush()
        recipe = Recipe(
            user_id=user_id,
            source_video_id=source.id,
            source_cache_id=cache.id,
            title="Crispy chicken",
            description="",
            notes=[],
            creator_name="Cook",
            source="tiktok",
            original_url=source.canonical_url,
            preparation_minutes=None,
            cooking_minutes=None,
            total_minutes=None,
            servings=Decimal(1),
            favorite=False,
            review_status="ready",
            revision=1,
            created_at=datetime(2026, 7, 27, tzinfo=UTC),
            updated_at=datetime(2026, 7, 27, tzinfo=UTC),
        )
        database.add(recipe)
        database.flush()
        database.add(
            RecipeImage(
                recipe_id=recipe.id,
                remote_url=remote_url,
                order_index=0,
            )
        )

    fetcher = RecordingFetcher()
    with sessions.begin() as database:
        count = ThumbnailBackfillService(fetcher=fetcher).run(database)

    with sessions() as database:
        cache = database.scalar(select(ExtractionCache))
        image = database.scalar(select(RecipeImage))
        assert count == 1
        assert fetcher.candidates == [remote_url]
        assert cache is not None
        assert cache.thumbnail_remote_url is None
        assert cache.thumbnail_object_key == (
            "thumbnails/tiktok-video/durable.webp"
        )
        assert image is not None
        assert image.remote_url is None
        assert image.object_key == "thumbnails/tiktok-video/durable.webp"
