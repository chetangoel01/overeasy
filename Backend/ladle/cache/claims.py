from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import ExtractionClaim, SourceVideo


class ClaimRole(StrEnum):
    LEADER = "leader"
    FOLLOWER = "follower"


class ClaimLost(Exception):
    """The caller no longer owns the live version of an extraction claim."""


class SourceVideoNotFound(Exception):
    pass


@dataclass(frozen=True)
class ClaimLease:
    claim_id: UUID
    source_video_id: UUID
    owner_job_id: UUID
    version: int
    role: ClaimRole
    lease_expires_at: datetime


class ExtractionClaimService:
    def __init__(self, *, clock: Clock, lease_duration: timedelta) -> None:
        self._clock = clock
        self._lease_duration = lease_duration

    def acquire(
        self,
        database: Session,
        *,
        source_video_id: UUID,
        job_id: UUID,
    ) -> ClaimLease:
        source = database.execute(
            select(SourceVideo)
            .where(SourceVideo.id == source_video_id)
            .with_for_update()
        ).scalar_one_or_none()
        if source is None:
            raise SourceVideoNotFound

        claim = self._active_claim(database, source_video_id)
        now = self._clock.now()
        if claim is None:
            claim = ExtractionClaim(
                id=uuid4(),
                source_video_id=source_video_id,
                owner_job_id=job_id,
                claim_version=1,
                lease_expires_at=now + self._lease_duration,
                heartbeat_at=now,
            )
            database.add(claim)
            database.flush()
            return self._lease(claim, role=ClaimRole.LEADER)

        if claim.lease_expires_at <= now:
            claim.owner_job_id = job_id
            claim.claim_version += 1
            claim.heartbeat_at = now
            claim.lease_expires_at = now + self._lease_duration
            database.flush()
            return self._lease(claim, role=ClaimRole.LEADER)

        if claim.owner_job_id == job_id:
            return self._lease(claim, role=ClaimRole.LEADER)

        return self._lease(claim, role=ClaimRole.FOLLOWER)

    def heartbeat(self, database: Session, lease: ClaimLease) -> ClaimLease:
        claim = self.assert_leader(database, lease, require_live=True)
        now = self._clock.now()
        claim.heartbeat_at = now
        claim.lease_expires_at = now + self._lease_duration
        database.flush()
        return self._lease(claim, role=ClaimRole.LEADER)

    def assert_leader(
        self,
        database: Session,
        lease: ClaimLease,
        *,
        require_live: bool = True,
    ) -> ExtractionClaim:
        claim = database.execute(
            select(ExtractionClaim)
            .where(ExtractionClaim.id == lease.claim_id)
            .with_for_update()
        ).scalar_one_or_none()
        if (
            claim is None
            or claim.released_at is not None
            or claim.owner_job_id != lease.owner_job_id
            or claim.claim_version != lease.version
            or (require_live and claim.lease_expires_at <= self._clock.now())
        ):
            raise ClaimLost
        return claim

    def release(self, database: Session, lease: ClaimLease) -> None:
        claim = self.assert_leader(database, lease, require_live=False)
        claim.released_at = self._clock.now()

    def _active_claim(
        self,
        database: Session,
        source_video_id: UUID,
    ) -> ExtractionClaim | None:
        return database.execute(
            select(ExtractionClaim)
            .where(
                ExtractionClaim.source_video_id == source_video_id,
                ExtractionClaim.released_at.is_(None),
            )
            .with_for_update()
        ).scalar_one_or_none()

    def _lease(
        self,
        claim: ExtractionClaim,
        *,
        role: ClaimRole,
    ) -> ClaimLease:
        return ClaimLease(
            claim_id=claim.id,
            source_video_id=claim.source_video_id,
            owner_job_id=claim.owner_job_id,
            version=claim.claim_version,
            role=role,
            lease_expires_at=claim.lease_expires_at,
        )
