from decimal import Decimal
from typing import Protocol
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from ladle.clock import Clock
from ladle.db.models import ProviderAttempt
from ladle.usage.limits import UsageLimitService


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
        limits: UsageLimitService | None = None,
        reservation_units: Decimal = Decimal(1),
    ) -> None:
        if not reservation_units.is_finite() or reservation_units <= 0:
            raise ValueError(
                "provider reservation estimate must be finite and positive"
            )
        self._sessions = session_factory
        self._clock = clock
        self._limits = limits
        self._reservation_units = reservation_units

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
            if (
                attempt is not None
                and attempt.status == "running"
                and Decimal(attempt.reserved_units) > 0
                and (
                    attempt.reservation_expires_at is None
                    or attempt.reservation_expires_at > self._clock.now()
                )
            ):
                self._update_running(
                    attempt,
                    external_job_id=external_job_id,
                    billed_units=billed_units,
                )
                return

            estimate = max(self._reservation_units, billed_units)
            reservation = (
                self._limits.reserve(database, estimated_units=estimate)
                if self._limits is not None
                else None
            )
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
                        reserved_units=(
                            reservation.units if reservation is not None else Decimal(0)
                        ),
                        budget_window_started_at=(
                            reservation.window_started_at
                            if reservation is not None
                            else None
                        ),
                        reservation_expires_at=(
                            reservation.expires_at if reservation is not None else None
                        ),
                        created_at=self._clock.now(),
                    )
                )
                return
            attempt.status = "running"
            attempt.failure_code = None
            attempt.completed_at = None
            attempt.latency_ms = None
            attempt.billed_units = Decimal(0)
            attempt.reserved_units = (
                reservation.units if reservation is not None else Decimal(0)
            )
            attempt.budget_window_started_at = (
                reservation.window_started_at if reservation is not None else None
            )
            attempt.reservation_expires_at = (
                reservation.expires_at if reservation is not None else None
            )
            self._update_running(
                attempt,
                external_job_id=external_job_id,
                billed_units=billed_units,
            )

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
            if attempt.status == "completed":
                return
            if attempt.status == "failed":
                return
            actual = max(attempt.billed_units or Decimal(0), billed_units)
            self._reconcile(database, attempt=attempt, actual_units=actual)
            attempt.status = "completed"
            attempt.billed_units = actual
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
            if attempt.status in {"completed", "failed"}:
                return
            actual = Decimal(attempt.billed_units or 0)
            self._reconcile(database, attempt=attempt, actual_units=actual)
            attempt.status = "failed"
            attempt.failure_code = failure_code
            attempt.completed_at = self._clock.now()

    @staticmethod
    def _update_running(
        attempt: ProviderAttempt,
        *,
        external_job_id: str | None,
        billed_units: Decimal,
    ) -> None:
        if attempt.external_job_id is None:
            attempt.external_job_id = external_job_id
        attempt.billed_units = max(attempt.billed_units or Decimal(0), billed_units)

    def _reconcile(
        self,
        database: Session,
        *,
        attempt: ProviderAttempt,
        actual_units: Decimal,
    ) -> None:
        reserved = Decimal(attempt.reserved_units)
        window_started_at = attempt.budget_window_started_at
        if self._limits is not None and window_started_at is not None:
            self._limits.reconcile(
                database,
                window_started_at=window_started_at,
                reserved_units=reserved,
                actual_units=actual_units,
            )
        attempt.reserved_units = Decimal(0)
        attempt.reservation_expires_at = None

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
