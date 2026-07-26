from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.db.models import ImportJob, ProviderAttempt, SourceVideo
from ladle.db.session import build_engine
from ladle.usage.ledger import ProviderUsageLedger
from ladle.usage.limits import UsageLimitExceeded, UsageLimitService
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_job(database: Session) -> UUID:
    user_id = seed_user(database)
    source_id = uuid4()
    job_id = uuid4()
    database.add(
        SourceVideo(
            id=source_id,
            platform="youtube",
            platform_video_id=f"usage-{source_id}",
            canonical_url=f"https://www.youtube.com/watch?v={source_id}",
            source_revision="1",
            source_metadata={},
        )
    )
    database.flush()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url=f"https://youtu.be/{source_id}",
            canonical_url=f"https://www.youtube.com/watch?v={source_id}",
            source="youtube",
            status="parsing",
            stage="extracting",
            retry_count=0,
            bypass_cache=False,
            idempotency_key=f"usage-{job_id}",
        )
    )
    database.flush()
    return job_id


@pytest.mark.integration
def test_attempt_ledger_is_idempotent_and_limit_counts_billed_units(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    limiter = UsageLimitService(
        clock=clock,
        window=timedelta(days=1),
        max_billed_units=Decimal("3"),
    )
    ledger = ProviderUsageLedger(
        session_factory=sessions,
        clock=clock,
        limits=limiter,
        reservation_units=Decimal("3"),
    )
    with Session(engine) as database, database.begin():
        job_id = seed_job(database)

    ledger.started(
        job_id=job_id,
        provider="supadata",
        operation="visual",
        idempotency_key="supadata:visual:1",
        external_job_id="external-1",
        billed_units=Decimal("3"),
    )
    ledger.started(
        job_id=job_id,
        provider="supadata",
        operation="visual",
        idempotency_key="supadata:visual:1",
        external_job_id="external-1",
        billed_units=Decimal("3"),
    )
    ledger.completed(
        job_id=job_id,
        idempotency_key="supadata:visual:1",
        billed_units=Decimal("3"),
        latency_ms=1250,
    )

    with Session(engine) as database:
        attempts = list(database.scalars(select(ProviderAttempt)))
        assert len(attempts) == 1
        assert attempts[0].external_job_id == "external-1"
        assert attempts[0].status == "completed"
        assert attempts[0].billed_units == Decimal("3")
        with pytest.raises(UsageLimitExceeded):
            limiter.ensure_available(database)

    engine.dispose()
