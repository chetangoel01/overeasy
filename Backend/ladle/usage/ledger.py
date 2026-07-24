from decimal import Decimal
from typing import Protocol
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from ladle.clock import Clock
from ladle.db.models import ProviderAttempt


class ProviderUsageSink(Protocol):
    def existing_external_job_id(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
    ) -> str | None: ...

    def started(
        self,
        *,
        job_id: UUID,
        provider: str,
        operation: str,
        idempotency_key: str,
        external_job_id: str | None,
        billed_units: Decimal,
    ) -> None: ...

    def completed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        billed_units: Decimal,
        latency_ms: int | None,
    ) -> None: ...

    def failed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        failure_code: str,
    ) -> None: ...


class NullProviderUsageSink:
    def existing_external_job_id(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
    ) -> str | None:
        del job_id, idempotency_key
        return None

    def started(
        self,
        *,
        job_id: UUID,
        provider: str,
        operation: str,
        idempotency_key: str,
        external_job_id: str | None,
        billed_units: Decimal,
    ) -> None:
        del (
            job_id,
            provider,
            operation,
            idempotency_key,
            external_job_id,
            billed_units,
        )

    def completed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        billed_units: Decimal,
        latency_ms: int | None,
    ) -> None:
        del job_id, idempotency_key, billed_units, latency_ms

    def failed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        failure_code: str,
    ) -> None:
        del job_id, idempotency_key, failure_code


class ProviderUsageLedger:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        clock: Clock,
    ) -> None:
        self._sessions = session_factory
        self._clock = clock

    def existing_external_job_id(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
    ) -> str | None:
        with self._sessions() as database:
            attempt = database.scalar(
                select(ProviderAttempt).where(
                    ProviderAttempt.import_job_id == job_id,
                    ProviderAttempt.idempotency_key == idempotency_key,
                )
            )
            return attempt.external_job_id if attempt is not None else None

    def started(
        self,
        *,
        job_id: UUID,
        provider: str,
        operation: str,
        idempotency_key: str,
        external_job_id: str | None,
        billed_units: Decimal,
    ) -> None:
        with self._sessions.begin() as database:
            attempt = self._find_locked(database, job_id, idempotency_key)
            if attempt is None:
                database.add(
                    ProviderAttempt(
                        id=uuid4(),
                        import_job_id=job_id,
                        provider=provider,
                        operation=operation,
                        idempotency_key=idempotency_key,
                        external_job_id=external_job_id,
                        status="running",
                        billed_units=billed_units,
                        created_at=self._clock.now(),
                    )
                )
                return
            if attempt.external_job_id is None:
                attempt.external_job_id = external_job_id
            attempt.billed_units = max(attempt.billed_units or Decimal(0), billed_units)

    def completed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        billed_units: Decimal,
        latency_ms: int | None,
    ) -> None:
        with self._sessions.begin() as database:
            attempt = self._find_locked(database, job_id, idempotency_key)
            if attempt is None:
                raise ValueError("provider attempt was not started")
            attempt.status = "completed"
            attempt.billed_units = max(attempt.billed_units or Decimal(0), billed_units)
            attempt.latency_ms = latency_ms
            attempt.completed_at = self._clock.now()

    def failed(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
        failure_code: str,
    ) -> None:
        with self._sessions.begin() as database:
            attempt = self._find_locked(database, job_id, idempotency_key)
            if attempt is None:
                raise ValueError("provider attempt was not started")
            attempt.status = "failed"
            attempt.failure_code = failure_code
            attempt.completed_at = self._clock.now()

    def _find_locked(
        self,
        database: Session,
        job_id: UUID,
        idempotency_key: str,
    ) -> ProviderAttempt | None:
        return database.execute(
            select(ProviderAttempt)
            .where(
                ProviderAttempt.import_job_id == job_id,
                ProviderAttempt.idempotency_key == idempotency_key,
            )
            .with_for_update()
        ).scalar_one_or_none()
