import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import delete, func, select, update
from sqlalchemy.orm import Session

from alembic import command
from ladle.cache.claims import ClaimLost, ExtractionClaimService
from ladle.cache.maintenance import CacheMaintenanceService
from ladle.cache.service import (
    CacheDisposition,
    ExtractionCacheService,
)
from ladle.contracts.recipes import RecipeDTO, RecipeSource
from ladle.db.models import (
    ExtractionCache,
    ImportJob,
    Ingredient,
    Recipe,
    RecipeChange,
    RecipeImage,
    RecipeSlotReservation,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.imports.reservations import ReservationService
from ladle.recipes.template_clone import RecipeTemplate, RecipeTemplateCloner
from tests.integration.recipes.test_recipe_service import manual_recipe, seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RecordingCleaner:
    deleted: list[str]

    def delete(self, key: str) -> None:
        self.deleted.append(key)


def extracted_recipe() -> RecipeDTO:
    return manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=shared-cache",
            "is_favorite": True,
            "revision": 8,
        }
    )


def seed_job(
    database: Session,
    *,
    source_id: UUID,
    index: int,
    bypass_cache: bool = False,
) -> UUID:
    user_id = seed_user(database)
    job_id = uuid4()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url="https://youtu.be/shared-cache",
            canonical_url="https://www.youtube.com/watch?v=shared-cache",
            source="youtube",
            status="parsing",
            stage="admitted",
            retry_count=0,
            bypass_cache=bypass_cache,
            idempotency_key=f"cache-{index}-{job_id}",
        )
    )
    database.add(
        RecipeSlotReservation(
            id=uuid4(),
            user_id=user_id,
            import_job_id=job_id,
            state="reserved",
            created_at=datetime(2026, 7, 23, 21, 0, tzinfo=UTC),
            expires_at=datetime(2026, 7, 23, 22, 0, tzinfo=UTC),
        )
    )
    database.flush()
    return job_id


def build_services(
    clock: FrozenClock,
) -> tuple[ExtractionClaimService, ExtractionCacheService]:
    reservations = ReservationService(clock=clock, lifetime=timedelta(hours=1))
    claims = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    cloner = RecipeTemplateCloner(clock=clock, reservations=reservations)
    return claims, ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=cloner,
        public_recheck_after=timedelta(days=7),
    )


@pytest.mark.integration
def test_shared_completion_fans_out_and_later_hit_clones_fresh_graphs(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    _, cache = build_services(clock)
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="shared-cache",
                canonical_url="https://www.youtube.com/watch?v=shared-cache",
                public_access_confirmed_at=clock.now(),
                source_revision="1",
                source_metadata={},
            )
        )
        leader_job = seed_job(database, source_id=source_id, index=1)
        follower_job = seed_job(database, source_id=source_id, index=2)

    with Session(engine) as database, database.begin():
        leader = cache.route(database, job_id=leader_job)
    assert leader.disposition == CacheDisposition.LEADER
    assert leader.claim is not None

    with Session(engine) as database, database.begin():
        follower = cache.route(database, job_id=follower_job)
    assert follower.disposition == CacheDisposition.FOLLOWER

    template = RecipeTemplate.from_recipe(extracted_recipe())
    serialized = template.model_dump(mode="json", by_alias=True)
    serialized_text = json.dumps(serialized)
    assert '"id"' not in serialized_text
    assert "isFavorite" not in serialized
    assert "revision" not in serialized
    assert "createdAt" not in serialized

    with Session(engine) as database, database.begin():
        completed = cache.complete_shared(
            database,
            claim=leader.claim,
            template=template,
            contract_version="v1",
            prompt_version="recipe-v1",
            model_id="claude-sonnet",
            thumbnail_object_key="thumbnails/shared-cache.jpg",
        )
    assert set(completed.job_ids) == {leader_job, follower_job}

    with Session(engine) as database:
        recipes = list(database.scalars(select(Recipe).order_by(Recipe.id)))
        ingredient_ids = set(database.scalars(select(Ingredient.id)))
        assert len(recipes) == 2
        assert len({recipe.id for recipe in recipes}) == 2
        assert len(ingredient_ids) == len(template.ingredients) * 2
        assert all(not recipe.favorite for recipe in recipes)
        assert all(
            recipe.source_cache_id == completed.cache_entry_id for recipe in recipes
        )
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeSlotReservation)
                .where(RecipeSlotReservation.state == "consumed")
            )
            == 2
        )
        assert database.scalar(select(func.count()).select_from(RecipeChange)) == 2

    with Session(engine) as database, database.begin():
        later_job = seed_job(database, source_id=source_id, index=3)
    with Session(engine) as database, database.begin():
        hit = cache.route(database, job_id=later_job)
    assert hit.disposition == CacheDisposition.HIT
    assert hit.recipe_id not in {recipe.id for recipe in recipes}

    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(Recipe)) == 3
        assert database.scalar(select(func.count()).select_from(ExtractionCache)) == 1

    engine.dispose()


@pytest.mark.integration
def test_old_leader_cannot_complete_and_bypass_never_reads_or_writes_cache(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    claims, cache = build_services(clock)
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="fenced-cache",
                canonical_url="https://www.youtube.com/watch?v=fenced-cache",
                public_access_confirmed_at=clock.now(),
                source_revision="1",
                source_metadata={},
            )
        )
        first_job = seed_job(database, source_id=source_id, index=1)
        takeover_job = seed_job(database, source_id=source_id, index=2)
        bypass_job = seed_job(
            database,
            source_id=source_id,
            index=3,
            bypass_cache=True,
        )

    with Session(engine) as database, database.begin():
        first = cache.route(database, job_id=first_job)
    assert first.claim is not None
    clock.value += timedelta(minutes=6)
    with Session(engine) as database, database.begin():
        takeover = claims.acquire(
            database,
            source_video_id=source_id,
            job_id=takeover_job,
        )

    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(ClaimLost),
    ):
        cache.complete_shared(
            database,
            claim=first.claim,
            template=RecipeTemplate.from_recipe(extracted_recipe()),
            contract_version="v1",
            prompt_version="recipe-v1",
            model_id="claude-sonnet",
        )

    with Session(engine) as database, database.begin():
        bypass = cache.route(database, job_id=bypass_job)
    assert bypass.disposition == CacheDisposition.BYPASS
    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(ExtractionCache)) == 0

    with Session(engine) as database, database.begin():
        claims.release(database, takeover)
    engine.dispose()


@pytest.mark.integration
def test_stale_public_cache_rechecks_and_private_observation_invalidates(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    _, cache = build_services(clock)
    maintenance = CacheMaintenanceService(clock=clock)
    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="stale-cache",
                canonical_url="https://www.youtube.com/watch?v=stale-cache",
                public_access_confirmed_at=clock.now() - timedelta(days=8),
                source_revision="1",
                source_metadata={},
            )
        )
        database.flush()
        entry = ExtractionCache(
            id=uuid4(),
            source_video_id=source_id,
            source_revision="1",
            contract_version="v1",
            prompt_version="recipe-v1",
            model_id="claude-sonnet",
            template_json=RecipeTemplate.from_recipe(extracted_recipe()).model_dump(
                mode="json",
                by_alias=True,
            ),
            review_status="ready",
            thumbnail_object_key="thumbnails/stale-cache.jpg",
            created_at=clock.now() - timedelta(days=8),
        )
        database.add(entry)
        job_id = seed_job(database, source_id=source_id, index=1)

    with Session(engine) as database, database.begin():
        stale = cache.route(database, job_id=job_id)
    assert stale.disposition == CacheDisposition.RECHECK

    with Session(engine) as database, database.begin():
        maintenance.confirm_public(database, source_video_id=source_id)
    with Session(engine) as database, database.begin():
        hit = cache.route(database, job_id=job_id)
    assert hit.disposition == CacheDisposition.HIT

    with Session(engine) as database, database.begin():
        maintenance.mark_private_or_deleted(database, source_video_id=source_id)
    with Session(engine) as database:
        stored_entry = database.scalar(
            select(ExtractionCache).where(ExtractionCache.source_video_id == source_id)
        )
        stored_source = database.get(SourceVideo, source_id)
        assert stored_entry is not None
        assert stored_entry.invalidated_at == clock.now()
        assert stored_source is not None
        assert stored_source.public_access_confirmed_at is None

    with Session(engine) as database, database.begin():
        negative_job = seed_job(database, source_id=source_id, index=2)
    with Session(engine) as database, database.begin():
        negative = cache.route(database, job_id=negative_job)
    assert negative.disposition == CacheDisposition.NEGATIVE

    clock.value += timedelta(minutes=16)
    with Session(engine) as database, database.begin():
        assert maintenance.purge_expired_negative_entries(database) == 1
        post_expiry_job = seed_job(database, source_id=source_id, index=3)
    with Session(engine) as database, database.begin():
        post_expiry = cache.route(database, job_id=post_expiry_job)
    assert post_expiry.disposition == CacheDisposition.LEADER

    cleaner = RecordingCleaner(deleted=[])
    with Session(engine) as database, database.begin():
        assert (
            maintenance.delete_unreferenced_thumbnails(
                database,
                storage=cleaner,
            )
            == 0
        )
    assert cleaner.deleted == []

    with Session(engine) as database, database.begin():
        database.execute(
            update(Recipe)
            .where(Recipe.source_cache_id == stored_entry.id)
            .values(source_cache_id=None)
        )
        assert (
            maintenance.delete_unreferenced_thumbnails(
                database,
                storage=cleaner,
            )
            == 0
        )
        database.execute(
            delete(RecipeImage).where(
                RecipeImage.object_key == "thumbnails/stale-cache.jpg"
            )
        )
        assert (
            maintenance.delete_unreferenced_thumbnails(
                database,
                storage=cleaner,
            )
            == 1
        )
    assert cleaner.deleted == ["thumbnails/stale-cache.jpg"]

    engine.dispose()
