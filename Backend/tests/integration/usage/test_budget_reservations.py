from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from threading import Barrier

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import sessionmaker

from alembic import command
from ladle.db.models import ProviderAttempt, ProviderBudgetWindow
from ladle.db.session import build_engine
from ladle.usage.ledger import ProviderUsageLedger
from ladle.usage.limits import UsageLimitExceeded, UsageLimitService
from tests.integration.test_migrations import alembic_config
from tests.integration.usage.test_limits import seed_job


@dataclass
class MutableClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.mark.integration
def test_parallel_workers_reserve_reconcile_and_release_provider_budget(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    limits = UsageLimitService(
        clock=clock,
        window=timedelta(days=1),
        max_billed_units=Decimal("5"),
        reservation_lifetime=timedelta(minutes=30),
    )
    ledger = ProviderUsageLedger(
        session_factory=sessions,
        clock=clock,
        limits=limits,
        reservation_units=Decimal("3"),
    )
    with sessions.begin() as database:
        jobs = [seed_job(database) for _ in range(4)]
    rendezvous = Barrier(3)

    def start(index: int) -> str:
        try:
            rendezvous.wait()
            ledger.started(
                job_id=jobs[index],
                provider="supadata",
                operation="visual",
                idempotency_key=f"visual:{index}",
                external_job_id=None,
                billed_units=Decimal(0),
            )
            return "reserved"
        except UsageLimitExceeded:
            return "limited"

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(start, 0)
        second = executor.submit(start, 1)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]
    assert sorted(results) == ["limited", "reserved"]

    with sessions() as database:
        running = database.scalar(
            select(ProviderAttempt).where(ProviderAttempt.status == "running")
        )
        assert running is not None
        winner = running.import_job_id
        window = database.scalar(select(ProviderBudgetWindow))
        assert window is not None
        assert window.reserved_units == Decimal("3")
        assert window.spent_units == Decimal(0)

    ledger.failed(
        job_id=winner,
        idempotency_key=("visual:0" if winner == jobs[0] else "visual:1"),
        failure_code="ProviderUnavailable",
    )
    loser_index = 1 if winner == jobs[0] else 0
    ledger.started(
        job_id=jobs[loser_index],
        provider="supadata",
        operation="visual",
        idempotency_key=f"visual:{loser_index}",
        external_job_id=None,
        billed_units=Decimal(0),
    )
    ledger.completed(
        job_id=jobs[loser_index],
        idempotency_key=f"visual:{loser_index}",
        billed_units=Decimal("2"),
        latency_ms=20,
    )
    ledger.started(
        job_id=jobs[2],
        provider="supadata",
        operation="visual",
        idempotency_key="visual:2",
        external_job_id=None,
        billed_units=Decimal(0),
    )
    with pytest.raises(UsageLimitExceeded):
        ledger.started(
            job_id=jobs[3],
            provider="supadata",
            operation="visual",
            idempotency_key="visual:3",
            external_job_id=None,
            billed_units=Decimal(0),
        )

    with sessions() as database:
        window = database.scalar(select(ProviderBudgetWindow))
        assert window is not None
        assert window.spent_units == Decimal("2")
        assert window.reserved_units == Decimal("3")
        assert database.scalar(select(func.count()).select_from(ProviderAttempt)) == 3
    engine.dispose()


@pytest.mark.integration
def test_retry_does_not_reconcile_a_prior_failed_charge_twice(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    ledger = ProviderUsageLedger(
        session_factory=sessions,
        clock=clock,
        limits=UsageLimitService(
            clock=clock,
            window=timedelta(days=1),
            max_billed_units=Decimal("10"),
        ),
        reservation_units=Decimal("3"),
    )
    with sessions.begin() as database:
        job_id = seed_job(database)

    for billed_units in (Decimal("1"), Decimal(0)):
        ledger.started(
            job_id=job_id,
            provider="supadata",
            operation="transcript",
            idempotency_key="transcript:retry",
            external_job_id="external-1",
            billed_units=Decimal(0),
        )
        ledger.started(
            job_id=job_id,
            provider="supadata",
            operation="transcript",
            idempotency_key="transcript:retry",
            external_job_id="external-1",
            billed_units=billed_units,
        )
        ledger.failed(
            job_id=job_id,
            idempotency_key="transcript:retry",
            failure_code="ProviderUnavailable",
        )

    with sessions() as database:
        window = database.scalar(select(ProviderBudgetWindow))
        assert window is not None
        assert window.spent_units == Decimal("1")
        assert window.reserved_units == Decimal(0)
    engine.dispose()


@pytest.mark.integration
def test_reprocessing_after_a_completed_attempt_reserves_before_dispatch_again(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    ledger = ProviderUsageLedger(
        session_factory=sessions,
        clock=clock,
        limits=UsageLimitService(
            clock=clock,
            window=timedelta(days=1),
            max_billed_units=Decimal("10"),
        ),
        reservation_units=Decimal("3"),
    )
    with sessions.begin() as database:
        job_id = seed_job(database)

    ledger.started(
        job_id=job_id,
        provider="openrouter",
        operation="recipeExtraction",
        idempotency_key="extract:retry",
        external_job_id=None,
        billed_units=Decimal(0),
    )
    ledger.completed(
        job_id=job_id,
        idempotency_key="extract:retry",
        billed_units=Decimal(1),
        latency_ms=10,
    )
    ledger.started(
        job_id=job_id,
        provider="openrouter",
        operation="recipeExtraction",
        idempotency_key="extract:retry",
        external_job_id=None,
        billed_units=Decimal(0),
    )

    with sessions() as database:
        attempt = database.scalar(select(ProviderAttempt))
        window = database.scalar(select(ProviderBudgetWindow))
        assert attempt is not None
        assert window is not None
        assert attempt.status == "running"
        assert attempt.reserved_units == Decimal("3")
        assert window.spent_units == Decimal(1)
        assert window.reserved_units == Decimal("3")
    engine.dispose()


@pytest.mark.integration
def test_provider_cost_accumulates_across_retries_without_limiting_calls(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = MutableClock(datetime(2026, 7, 30, 21, 0, tzinfo=UTC))
    ledger = ProviderUsageLedger(
        session_factory=sessions,
        clock=clock,
        limits=UsageLimitService(
            clock=clock,
            window=timedelta(days=1),
            max_billed_units=Decimal("10"),
        ),
        reservation_units=Decimal("1"),
    )
    with sessions.begin() as database:
        job_id = seed_job(database)

    for cost in (Decimal("0.125"), Decimal("999.25")):
        ledger.started(
            job_id=job_id,
            provider="openrouter",
            operation="recipeExtraction",
            idempotency_key="extract:cost-retry",
            external_job_id=None,
            billed_units=Decimal(0),
        )
        ledger.completed(
            job_id=job_id,
            idempotency_key="extract:cost-retry",
            billed_units=Decimal(1),
            cost_usd=cost,
            latency_ms=10,
        )

    with sessions() as database:
        attempt = database.scalar(select(ProviderAttempt))
        window = database.scalar(select(ProviderBudgetWindow))
        assert attempt is not None
        assert window is not None
        assert attempt.cost_usd == Decimal("999.375")
        assert window.spent_units == Decimal("2")
    engine.dispose()
