from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.contracts.recipes import RecipeSource
from ladle.db.models import (
    ExtractionCache,
    ImportJob,
    Recipe,
    RecipeSlotReservation,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.imports.orchestrator import ImportOrchestrator, ProcessOutcome
from ladle.imports.reservations import ReservationService
from ladle.observability.metrics import MetricsRegistry
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


def seed_import(database: Session, *, source_id: UUID, suffix: str) -> UUID:
    user_id = seed_user(database)
    job_id = uuid4()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url="https://youtu.be/walking-test",
            canonical_url="https://www.youtube.com/watch?v=walking-test",
            source="youtube",
            status="parsing",
            stage="admitted",
            retry_count=0,
            bypass_cache=False,
            idempotency_key=f"walking-{suffix}",
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


@pytest.mark.integration
def test_worker_round_trip_then_shared_hit_and_duplicate_delivery(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    reservations = ReservationService(clock=clock, lifetime=timedelta(hours=1))
    claims = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    metrics = MetricsRegistry()
    cache = ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=RecipeTemplateCloner(clock=clock, reservations=reservations),
        public_recheck_after=timedelta(days=7),
        metrics=metrics,
    )
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=walking-test",
        }
    )
    acquirer = FakeAcquirer()
    extractor = FakeExtractor(RecipeTemplate.from_recipe(recipe))
    orchestrator = ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=acquirer,
        extractor=extractor,
        clock=clock,
        metrics=metrics,
    )

    with Session(engine) as database, database.begin():
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="walking-test",
                canonical_url="https://www.youtube.com/watch?v=walking-test",
                source_revision="1",
                source_metadata={},
            )
        )
        first_job = seed_import(database, source_id=source_id, suffix="first")

    assert orchestrator.process(first_job) == ProcessOutcome.COMPLETED
    assert orchestrator.process(first_job) == ProcessOutcome.ALREADY_COMPLETED

    with Session(engine) as database, database.begin():
        second_job = seed_import(database, source_id=source_id, suffix="second")
    assert orchestrator.process(second_job) == ProcessOutcome.CACHE_HIT

    clock.value += timedelta(days=8)
    with Session(engine) as database, database.begin():
        third_job = seed_import(database, source_id=source_id, suffix="stale")
    assert orchestrator.process(third_job) == ProcessOutcome.CACHE_HIT

    assert len(acquirer.calls) == 1
    assert acquirer.public_checks == [source_id]
    assert len(extractor.calls) == 1
    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(Recipe)) == 3
        assert database.scalar(select(func.count()).select_from(ExtractionCache)) == 1
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeSlotReservation)
                .where(RecipeSlotReservation.state == "consumed")
            )
            == 3
        )
        jobs = list(database.scalars(select(ImportJob).order_by(ImportJob.created_at)))
        assert all(job.status == "ready" for job in jobs)
    rendered_metrics = metrics.render()
    assert 'ladle_cache_total{disposition="leader"} 1' in rendered_metrics
    assert 'ladle_cache_total{disposition="hit"} 2' in rendered_metrics
    assert 'ladle_cache_total{disposition="recheck"} 1' in rendered_metrics
    assert (
        'ladle_import_jobs_total{source="youtube",status="ready"} 4' in rendered_metrics
    )

    engine.dispose()
