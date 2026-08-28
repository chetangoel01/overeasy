"""An uploaded thumbnail must never outlive the import that stored it.

Thumbnail bytes are PUT into object storage *before* the completion
transaction opens. If that transaction rolls back, or the key is discarded
because the job finished some other way while extraction ran, no database row
ever references the object — and every cleanup path (cache maintenance, the
retention sweep, account deletion) enumerates database rows only, so the
orphan would stay in the bucket forever.
"""

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from pydantic import SecretStr
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.acquisition.models import SourceVideoDescriptor
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.contracts.recipes import RecipeSource
from ladle.crypto.private_text import build_private_text_cipher
from ladle.db.models import (
    ExtractionCache,
    ImportJob,
    ObjectDeletionQueue,
    Recipe,
    RecipeImage,
    RecipeSlotReservation,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.imports.orchestrator import ImportOrchestrator, ProcessOutcome
from ladle.imports.reservations import ReservationService
from ladle.imports.thumbnails import ThumbnailAsset
from ladle.privacy.retention import ObjectDeletionProcessor
from ladle.recipes.template_clone import RecipeTemplate, RecipeTemplateCloner
from tests.fakes.acquisition import FakeAcquirer
from tests.fakes.extraction import FakeExtractor
from tests.integration.recipes.test_recipe_service import manual_recipe, seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeThumbnails:
    """Duck-typed stand-in for OEmbedThumbnailFetcher over a dict bucket."""

    objects: dict[str, bytes] = field(default_factory=dict)
    stored: list[str] = field(default_factory=list)

    def download(
        self,
        source: SourceVideoDescriptor,
        *,
        candidate_url: str | None = None,
    ) -> ThumbnailAsset:
        del source, candidate_url
        return ThumbnailAsset(
            data=b"jpeg-bytes",
            content_type="image/jpeg",
            extension=".jpg",
        )

    def store(self, source: SourceVideoDescriptor, asset: ThumbnailAsset) -> str:
        key = f"thumbnails/{source.source_video_id}/{len(self.stored)}.jpg"
        self.objects[key] = asset.data
        self.stored.append(key)
        return key

    def delete(self, key: str) -> None:
        del self.objects[key]


@dataclass
class HookedExtractor(FakeExtractor):
    """Runs a callback mid-extraction, before the completion transaction."""

    hook: Callable[[], None] | None = None

    def extract(self, context: object, *, job_id: UUID) -> RecipeTemplate:
        if self.hook is not None:
            self.hook()
        return super().extract(context, job_id=job_id)  # type: ignore[arg-type]


def build_orchestrator(
    *,
    sessions: sessionmaker[Session],
    clock: FrozenClock,
    extractor: FakeExtractor,
    thumbnails: FakeThumbnails,
) -> ImportOrchestrator:
    reservations = ReservationService(clock=clock, lifetime=timedelta(hours=1))
    cloner = RecipeTemplateCloner(clock=clock, reservations=reservations)
    cache = ExtractionCacheService(
        clock=clock,
        claims=ExtractionClaimService(
            clock=clock,
            lease_duration=timedelta(minutes=5),
        ),
        cloner=cloner,
        public_recheck_after=timedelta(days=7),
    )
    return ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=FakeAcquirer(),
        extractor=extractor,
        clock=clock,
        private_text=build_private_text_cipher(
            active_key_id=None,
            keyring_json=None,
            legacy_key=SecretStr("thumbnail-discard-test-key"),
        ),
        private_completion=cloner,
        thumbnails=thumbnails,  # type: ignore[arg-type]
    )


def template() -> RecipeTemplate:
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=thumb-test",
        }
    )
    return RecipeTemplate.from_recipe(recipe)


def seed_source(database: Session) -> UUID:
    source_id = uuid4()
    database.add(
        SourceVideo(
            id=source_id,
            platform="youtube",
            platform_video_id=f"thumb-{source_id.hex[:8]}",
            canonical_url="https://www.youtube.com/watch?v=thumb-test",
            source_revision="1",
            source_metadata={},
        )
    )
    database.flush()
    return source_id


def seed_reimport_job(
    database: Session,
    *,
    source_id: UUID,
    now: datetime,
) -> UUID:
    user_id = seed_user(database)
    recipe_id = uuid4()
    database.add(
        Recipe(
            id=recipe_id,
            user_id=user_id,
            title="Existing recipe",
            description="",
            source="youtube",
            original_url="https://www.youtube.com/watch?v=thumb-test",
            servings=1,
            favorite=False,
            review_status="ready",
            revision=1,
            created_at=now,
            updated_at=now,
        )
    )
    database.flush()
    job_id = uuid4()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url="https://youtu.be/thumb-test",
            canonical_url="https://www.youtube.com/watch?v=thumb-test",
            source="youtube",
            status="parsing",
            stage="admitted",
            retry_count=0,
            bypass_cache=True,
            current_recipe_id=recipe_id,
            base_recipe_revision=1,
            idempotency_key=f"thumb-{job_id.hex[:8]}",
            updated_at=now,
        )
    )
    database.flush()
    return job_id


def queued_keys(database: Session) -> dict[str, ObjectDeletionQueue]:
    return {
        row.object_key: row
        for row in database.scalars(select(ObjectDeletionQueue)).all()
    }


@pytest.mark.integration
def test_rolled_back_completion_queues_the_uploaded_thumbnail_for_deletion(
    clean_postgres_url: str,
) -> None:
    """Recipe deleted mid-extraction: the completion raises, the upload must
    still end up queued for deletion, and the reaper must actually remove it.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    thumbnails = FakeThumbnails()

    with Session(engine) as database, database.begin():
        source_id = seed_source(database)
        job_id = seed_reimport_job(database, source_id=source_id, now=clock.now())

    def soft_delete_current_recipe() -> None:
        with Session(engine) as database, database.begin():
            job = database.get(ImportJob, job_id)
            assert job is not None and job.current_recipe_id is not None
            recipe = database.get(Recipe, job.current_recipe_id)
            assert recipe is not None
            recipe.deleted_at = clock.now()

    orchestrator = build_orchestrator(
        sessions=sessions,
        clock=clock,
        extractor=HookedExtractor(template(), hook=soft_delete_current_recipe),
        thumbnails=thumbnails,
    )

    with pytest.raises(ValueError, match="current recipe is unavailable"):
        orchestrator.process(job_id)

    assert thumbnails.stored, "the thumbnail was uploaded before the rollback"
    key = thumbnails.stored[0]
    with Session(engine) as database:
        queued = queued_keys(database)
        assert key in queued, "the orphaned upload must be queued for deletion"
        # Deletion is deferred so a completion transaction that is still in
        # flight can never lose its thumbnail to a concurrent sweep.
        assert queued[key].available_at > clock.now()
        assert queued[key].available_at == clock.now() + timedelta(hours=1)

    # The reaper must not touch the object before the grace period...
    with Session(engine) as database, database.begin():
        deleted = ObjectDeletionProcessor(clock=clock, maximum_attempts=5).process(
            database, storage=thumbnails
        )
    assert deleted == 0
    assert key in thumbnails.objects

    # ...and must remove it afterwards, closing the leak end to end.
    clock.value += timedelta(hours=2)
    with Session(engine) as database, database.begin():
        deleted = ObjectDeletionProcessor(clock=clock, maximum_attempts=5).process(
            database, storage=thumbnails
        )
    assert deleted == 1
    assert key not in thumbnails.objects

    engine.dispose()


@pytest.mark.integration
def test_job_finished_elsewhere_queues_the_discarded_thumbnail_for_deletion(
    clean_postgres_url: str,
) -> None:
    """Job cancelled while extraction ran: the completion transaction returns
    ALREADY_COMPLETED and silently drops the key — the upload must still be
    queued for deletion. No exception anywhere on this path.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    thumbnails = FakeThumbnails()

    with Session(engine) as database, database.begin():
        source_id = seed_source(database)
        job_id = seed_reimport_job(database, source_id=source_id, now=clock.now())

    def cancel_job() -> None:
        with Session(engine) as database, database.begin():
            job = database.get(ImportJob, job_id)
            assert job is not None
            job.status = "cancelled"
            job.stage = "cancelled"

    orchestrator = build_orchestrator(
        sessions=sessions,
        clock=clock,
        extractor=HookedExtractor(template(), hook=cancel_job),
        thumbnails=thumbnails,
    )

    assert orchestrator.process(job_id) == ProcessOutcome.ALREADY_COMPLETED

    key = thumbnails.stored[0]
    with Session(engine) as database:
        assert key in queued_keys(database), (
            "a discarded thumbnail key must be queued for deletion"
        )

    engine.dispose()


@pytest.mark.integration
def test_completed_import_keeps_its_thumbnail_out_of_the_deletion_queue(
    clean_postgres_url: str,
) -> None:
    """Happy path: the committed completion references the key, so the
    scheduled discard must be cancelled — the reaper must never delete a
    thumbnail that recipes and the cache entry point at.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    thumbnails = FakeThumbnails()

    with Session(engine) as database, database.begin():
        source_id = seed_source(database)
        user_id = seed_user(database)
        job_id = uuid4()
        database.add(
            ImportJob(
                id=job_id,
                user_id=user_id,
                source_video_id=source_id,
                source_url="https://youtu.be/thumb-test",
                canonical_url="https://www.youtube.com/watch?v=thumb-test",
                source="youtube",
                status="parsing",
                stage="admitted",
                retry_count=0,
                bypass_cache=False,
                idempotency_key="thumb-shared",
                updated_at=clock.now(),
            )
        )
        database.add(
            RecipeSlotReservation(
                id=uuid4(),
                user_id=user_id,
                import_job_id=job_id,
                state="reserved",
                created_at=clock.now(),
                expires_at=clock.now() + timedelta(hours=1),
            )
        )

    orchestrator = build_orchestrator(
        sessions=sessions,
        clock=clock,
        extractor=FakeExtractor(template()),
        thumbnails=thumbnails,
    )

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED

    key = thumbnails.stored[0]
    with Session(engine) as database:
        entry = database.scalars(select(ExtractionCache)).one()
        assert entry.thumbnail_object_key == key
        image = database.scalars(select(RecipeImage)).one()
        assert image.object_key == key
        assert queued_keys(database) == {}

    # Even a late reaper pass finds nothing to delete for this import.
    clock.value += timedelta(hours=2)
    with Session(engine) as database, database.begin():
        deleted = ObjectDeletionProcessor(clock=clock, maximum_attempts=5).process(
            database, storage=thumbnails
        )
    assert deleted == 0
    assert key in thumbnails.objects

    engine.dispose()
