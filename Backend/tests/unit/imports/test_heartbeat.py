from contextlib import nullcontext
from dataclasses import dataclass, field
from datetime import UTC, datetime
from threading import Event
from uuid import uuid4

import pytest

from ladle.cache.claims import ClaimLease, ClaimLost, ClaimRole
from ladle.imports.heartbeat import ClaimHeartbeatMonitor


def lease() -> ClaimLease:
    return ClaimLease(
        claim_id=uuid4(),
        source_video_id=uuid4(),
        owner_job_id=uuid4(),
        version=1,
        role=ClaimRole.LEADER,
        lease_expires_at=datetime(2026, 7, 26, 16, 0, tzinfo=UTC),
    )


@dataclass
class RecordingClaims:
    called: Event = field(default_factory=Event)
    error: Exception | None = None

    def heartbeat(self, database: object, current: ClaimLease) -> ClaimLease:
        del database
        self.called.set()
        if self.error is not None:
            raise self.error
        return current


class FakeSessions:
    def begin(self) -> nullcontext[object]:
        return nullcontext(object())


def test_monitor_renews_claim_while_provider_work_is_running() -> None:
    claims = RecordingClaims()
    monitor = ClaimHeartbeatMonitor(
        session_factory=FakeSessions(),  # type: ignore[arg-type]
        claims=claims,  # type: ignore[arg-type]
        interval_seconds=0.01,
    )

    with monitor.monitor(lease()):
        assert claims.called.wait(timeout=1)


def test_monitor_surfaces_a_lost_claim_before_completion() -> None:
    claims = RecordingClaims(error=ClaimLost())
    monitor = ClaimHeartbeatMonitor(
        session_factory=FakeSessions(),  # type: ignore[arg-type]
        claims=claims,  # type: ignore[arg-type]
        interval_seconds=0.01,
    )

    with pytest.raises(ClaimLost), monitor.monitor(lease()):
        assert claims.called.wait(timeout=1)
