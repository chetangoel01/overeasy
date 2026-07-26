from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from pydantic import SecretStr
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.crypto.private_text import LocalPrivateTextCipher
from ladle.db.models import ImportJob, ImportQuotaEvent
from ladle.db.session import build_engine
from ladle.imports.admission import AdmissionService
from ladle.imports.quotas import ImportQuotaExceeded, ImportQuotaService
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.imports.transitions import ImportRetryService, ImportTransitionService
from tests.integration.recipes.test_recipe_service import seed_user
from tests.integration.test_migrations import alembic_config


@dataclass
class MutableClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def admission(clock: MutableClock, quota: ImportQuotaService) -> AdmissionService:
    return AdmissionService(
        parser=SourceIdentityParser(),
        reservations=ReservationService(clock=clock, lifetime=timedelta(hours=1)),
        clock=clock,
        quota=quota,
    )


def submit(
    service: AdmissionService,
    database: Session,
    *,
    user_id: UUID,
    key: str,
) -> UUID:
    result = service.admit(
        database,
        job_id=uuid4(),
        user_id=user_id,
        source_url=f"https://youtu.be/{key}",
        allow_duplicate=False,
        idempotency_key=key,
    )
    return result.job_id


@pytest.mark.integration
def test_import_quota_counts_idempotently_across_daily_and_monthly_windows(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    quota = ImportQuotaService(clock=clock, daily_limit=2, monthly_limit=3)
    service = admission(clock, quota)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        first = submit(service, database, user_id=user_id, key="quota-first")
        submit(service, database, user_id=user_id, key="quota-second")
        repeated = service.admit(
            database,
            job_id=uuid4(),
            user_id=user_id,
            source_url="https://youtu.be/quota-first",
            allow_duplicate=False,
            idempotency_key="quota-first",
        )
        assert repeated.job_id == first

    with (
        pytest.raises(ImportQuotaExceeded) as daily,
        Session(engine) as database,
        database.begin(),
    ):
        submit(service, database, user_id=user_id, key="quota-third")
    assert daily.value.period == "daily"
    assert daily.value.retry_at == datetime(2026, 7, 31, tzinfo=UTC)

    clock.value = datetime(2026, 7, 31, 1, 0, tzinfo=UTC)
    with Session(engine) as database, database.begin():
        submit(service, database, user_id=user_id, key="quota-third")

    with (
        pytest.raises(ImportQuotaExceeded) as monthly,
        Session(engine) as database,
        database.begin(),
    ):
        submit(service, database, user_id=user_id, key="quota-fourth")
    assert monthly.value.period == "monthly"
    assert monthly.value.retry_at == datetime(2026, 8, 1, tzinfo=UTC)

    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(ImportQuotaEvent)) == 3
        assert database.scalar(select(func.count()).select_from(ImportJob)) == 3
    engine.dispose()


@pytest.mark.integration
def test_parallel_submissions_cannot_oversubscribe_a_user_quota(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    service = admission(
        clock,
        ImportQuotaService(clock=clock, daily_limit=1, monthly_limit=10),
    )
    with sessions.begin() as database:
        user_id = seed_user(database)
    rendezvous = Barrier(3)

    def attempt(index: int) -> str:
        try:
            with sessions.begin() as database:
                rendezvous.wait()
                submit(service, database, user_id=user_id, key=f"parallel-{index}")
            return "admitted"
        except ImportQuotaExceeded:
            return "limited"

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(attempt, 1)
        second = executor.submit(attempt, 2)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]

    assert sorted(results) == ["admitted", "limited"]
    with sessions() as database:
        assert database.scalar(select(func.count()).select_from(ImportQuotaEvent)) == 1
        assert database.scalar(select(func.count()).select_from(ImportJob)) == 1
    engine.dispose()


@pytest.mark.integration
def test_retries_consume_the_same_user_quota(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    quota = ImportQuotaService(clock=clock, daily_limit=2, monthly_limit=10)
    reservations = ReservationService(clock=clock, lifetime=timedelta(hours=1))
    service = AdmissionService(
        parser=SourceIdentityParser(),
        reservations=reservations,
        clock=clock,
        quota=quota,
    )
    retry = ImportRetryService(
        clock=clock,
        reservations=reservations,
        private_text=LocalPrivateTextCipher(SecretStr("quota-test-key")),
        quota=quota,
    )
    transitions = ImportTransitionService(clock=clock, reservations=reservations)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        job_id = submit(service, database, user_id=user_id, key="quota-retry")
        job = database.get(ImportJob, job_id)
        assert job is not None
        transitions.fail(
            database,
            job_id=job.id,
            source_video_id=job.source_video_id,
            failure_reason="parserUnavailable",
            diagnostic_code="test",
            include_shared_followers=False,
        )
        retry.retry(
            database,
            user_id=user_id,
            job_id=job_id,
            correction_notes=None,
            pasted_text=None,
        )
        transitions.fail(
            database,
            job_id=job.id,
            source_video_id=job.source_video_id,
            failure_reason="parserUnavailable",
            diagnostic_code="test",
            include_shared_followers=False,
        )

    with (
        pytest.raises(ImportQuotaExceeded),
        Session(engine) as database,
        database.begin(),
    ):
        retry.retry(
            database,
            user_id=user_id,
            job_id=job_id,
            correction_notes=None,
            pasted_text=None,
        )

    with Session(engine) as database:
        operations = list(
            database.scalars(
                select(ImportQuotaEvent.operation).order_by(
                    ImportQuotaEvent.occurred_at,
                    ImportQuotaEvent.operation,
                )
            )
        )
        assert sorted(operations) == ["retry", "submit"]
    engine.dispose()
