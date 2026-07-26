from collections.abc import Iterator
from contextlib import contextmanager
from threading import Event, Thread

from sqlalchemy.orm import Session, sessionmaker

from ladle.cache.claims import ClaimLease, ExtractionClaimService


class ClaimHeartbeatMonitor:
    """Renew a claim from a separate session while synchronous work blocks."""

    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        claims: ExtractionClaimService,
        interval_seconds: float,
    ) -> None:
        if interval_seconds <= 0:
            raise ValueError("heartbeat interval must be positive")
        self._sessions = session_factory
        self._claims = claims
        self._interval = interval_seconds

    @contextmanager
    def monitor(self, lease: ClaimLease) -> Iterator[None]:
        stop = Event()
        failures: list[BaseException] = []

        def renew() -> None:
            while not stop.wait(self._interval):
                try:
                    with self._sessions.begin() as database:
                        self._claims.heartbeat(database, lease)
                except BaseException as error:
                    failures.append(error)
                    stop.set()

        thread = Thread(
            target=renew,
            name=f"claim-heartbeat-{lease.claim_id}",
            daemon=True,
        )
        thread.start()
        try:
            yield
        except BaseException:
            raise
        finally:
            stop.set()
            thread.join()
        if failures:
            raise failures[0]
