"""Import submission must not park the event loop while it does blocking I/O.

FastAPI runs `async def` endpoints on the event loop and `def` endpoints in
the anyio threadpool. Every route in this app does blocking I/O (sync
SQLAlchemy sessions, sync Redis, sync broker publishes), so they are all
`def` — except that `submit_import` and `retry_import` were `async def`
(only to await the raw request body for the App Attest hash). One slow
import submission then stalled every other in-flight request on that
worker, including `GET /health/live`, whose timeout gets the pod restarted.
"""

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Event
from time import perf_counter, sleep
from typing import Any
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import ImportJob
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config

HEALTH_BUDGET_SECONDS = 0.75
STALL_SECONDS = 1.5


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RecordingDispatcher:
    calls: list[UUID]

    def enqueue(self, job_id: UUID) -> None:
        self.calls.append(job_id)


class StallingAttestation(AttestationService):
    """Development-mode attestation whose verify can be made slow.

    The stall stands in for any of the blocking calls the import handlers
    make on the request path (a slow Postgres row lock, a hung rate-limit
    Redis, a slow broker publish). It runs inside the handler, so where the
    handler executes decides who waits: only that request (threadpool), or
    the whole event loop (async handler).
    """

    def __init__(self) -> None:
        super().__init__(enforced=False)
        self.delay = 0.0
        self.entered = Event()

    def verify(self, *args: Any, **kwargs: Any) -> str:
        if self.delay:
            self.entered.set()
            sleep(self.delay)
        return "development"


def timed_health_check_during(
    client: TestClient,
    attestation: StallingAttestation,
    request: "ThreadPoolExecutor",
    send: Any,
) -> tuple[float, Any]:
    """Fire `send` on a worker thread, wait until it is inside the stalled
    handler, then measure how long /health/live takes to answer."""
    attestation.entered.clear()
    attestation.delay = STALL_SECONDS
    in_flight = request.submit(send)
    assert attestation.entered.wait(timeout=10)
    started = perf_counter()
    health = client.get("/health/live")
    elapsed = perf_counter() - started
    assert health.status_code == 200
    response = in_flight.result(timeout=30)
    attestation.delay = 0.0
    return elapsed, response


@pytest.mark.integration
def test_a_slow_import_submission_does_not_stall_other_requests(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    attestation = StallingAttestation()
    dispatcher = RecordingDispatcher(calls=[])
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=SessionService(
            access_tokens=access_tokens,
            refresh_tokens=RefreshTokenCodec(),
            refresh_lifetime=timedelta(days=30),
            rotation_grace=timedelta(seconds=5),
            clock=clock,
        ),
        access_tokens=access_tokens,
        attestation=attestation,
        import_dispatcher=dispatcher,
    )
    job_id = uuid4()

    with TestClient(app) as client, ThreadPoolExecutor(max_workers=1) as pool:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "loop-stall-device", "attestation": None},
        ).json()
        headers = {"Authorization": f"Bearer {guest['accessToken']}"}

        def submit() -> Any:
            return client.post(
                "/v1/imports",
                json={
                    "jobID": str(job_id),
                    "sourceURL": "https://youtu.be/loop-stall",
                    "allowDuplicate": False,
                    "idempotencyKey": "loop-stall",
                },
                headers=headers,
            )

        elapsed, submitted = timed_health_check_during(
            client, attestation, pool, submit
        )
        assert submitted.status_code == 202
        assert dispatcher.calls == [job_id]
        assert elapsed < HEALTH_BUDGET_SECONDS, (
            f"/health/live took {elapsed:.3f}s while a submission was in "
            "flight: the import handler is blocking the event loop"
        )

        # Same property for the retry endpoint, against a failed job.
        with Session(engine) as database, database.begin():
            database.execute(
                update(ImportJob)
                .where(ImportJob.id == job_id)
                .values(status="failed", stage="failed")
            )

        def retry() -> Any:
            return client.post(f"/v1/imports/{job_id}/retry", json={}, headers=headers)

        elapsed, retried = timed_health_check_during(client, attestation, pool, retry)
        assert retried.status_code == 202
        assert elapsed < HEALTH_BUDGET_SECONDS, (
            f"/health/live took {elapsed:.3f}s while a retry was in flight: "
            "the retry handler is blocking the event loop"
        )

    engine.dispose()
