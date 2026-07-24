from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.cache.claims import (
    ClaimLost,
    ClaimRole,
    ExtractionClaimService,
)
from ladle.db.models import ExtractionClaim, ImportJob, SourceVideo
from ladle.db.session import build_engine
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_source_and_jobs(
    database: Session, *, count: int = 2
) -> tuple[UUID, list[UUID]]:
    source_id = uuid4()
    database.add(
        SourceVideo(
            id=source_id,
            platform="youtube",
            platform_video_id=f"claim-{uuid4()}",
            canonical_url="https://www.youtube.com/watch?v=claim-test",
            source_revision="1",
            source_metadata={},
        )
    )
    job_ids: list[UUID] = []
    for index in range(count):
        user_id = seed_user(database)
        job_id = uuid4()
        job_ids.append(job_id)
        database.add(
            ImportJob(
                id=job_id,
                user_id=user_id,
                source_video_id=source_id,
                source_url="https://youtu.be/claim-test",
                canonical_url="https://www.youtube.com/watch?v=claim-test",
                source="youtube",
                status="parsing",
                stage="admitted",
                retry_count=0,
                bypass_cache=False,
                idempotency_key=f"claim-{index}",
            )
        )
    database.flush()
    return source_id, job_ids


@pytest.mark.integration
def test_concurrent_acquisition_has_one_leader_and_one_follower(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    service = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    with Session(engine) as database, database.begin():
        source_id, job_ids = seed_source_and_jobs(database)

    barrier = Barrier(2)

    def acquire(job_id: UUID) -> ClaimRole:
        with sessions.begin() as database:
            barrier.wait()
            return service.acquire(
                database,
                source_video_id=source_id,
                job_id=job_id,
            ).role

    with ThreadPoolExecutor(max_workers=2) as pool:
        roles = list(pool.map(acquire, job_ids))

    assert sorted(roles) == [ClaimRole.FOLLOWER, ClaimRole.LEADER]
    with Session(engine) as database:
        assert (
            database.scalar(
                select(func.count())
                .select_from(ExtractionClaim)
                .where(ExtractionClaim.released_at.is_(None))
            )
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_heartbeat_takeover_and_fencing_use_injected_time(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    service = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    with Session(engine) as database, database.begin():
        source_id, job_ids = seed_source_and_jobs(database)
        original = service.acquire(
            database,
            source_video_id=source_id,
            job_id=job_ids[0],
        )

    clock.value += timedelta(minutes=2)
    with Session(engine) as database, database.begin():
        renewed = service.heartbeat(database, original)
    assert renewed.lease_expires_at == clock.now() + timedelta(minutes=5)

    clock.value += timedelta(minutes=6)
    with Session(engine) as database, database.begin():
        takeover = service.acquire(
            database,
            source_video_id=source_id,
            job_id=job_ids[1],
        )
    assert takeover.role == ClaimRole.LEADER
    assert takeover.version == original.version + 1

    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(ClaimLost),
    ):
        service.heartbeat(database, original)
    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(ClaimLost),
    ):
        service.release(database, original)

    with Session(engine) as database, database.begin():
        service.release(database, takeover)
    with Session(engine) as database:
        assert (
            database.scalar(
                select(func.count())
                .select_from(ExtractionClaim)
                .where(ExtractionClaim.released_at.is_(None))
            )
            == 0
        )

    engine.dispose()


@pytest.mark.integration
def test_expired_owner_reacquisition_advances_fencing_version(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    service = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    with Session(engine) as database, database.begin():
        source_id, job_ids = seed_source_and_jobs(database, count=1)
        original = service.acquire(
            database,
            source_video_id=source_id,
            job_id=job_ids[0],
        )

    clock.value += timedelta(minutes=6)
    with Session(engine) as database, database.begin():
        replacement = service.acquire(
            database,
            source_video_id=source_id,
            job_id=job_ids[0],
        )
    assert replacement.version == original.version + 1
    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(ClaimLost),
    ):
        service.heartbeat(database, original)

    engine.dispose()
