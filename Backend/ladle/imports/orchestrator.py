from enum import StrEnum
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.protocol import VideoAcquirer
from ladle.cache.maintenance import CacheMaintenanceService
from ladle.cache.service import CacheDisposition, ExtractionCacheService
from ladle.clock import Clock
from ladle.db.models import ImportJob, SourceVideo
from ladle.extraction.protocol import RecipeExtractor
from ladle.usage.limits import UsageLimitService


class ProcessOutcome(StrEnum):
    COMPLETED = "completed"
    CACHE_HIT = "cacheHit"
    FOLLOWER = "follower"
    ALREADY_COMPLETED = "alreadyCompleted"
    RECHECK_REQUIRED = "recheckRequired"
    BYPASS_REQUIRED = "bypassRequired"


class ImportOrchestrator:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        cache: ExtractionCacheService,
        acquirer: VideoAcquirer,
        extractor: RecipeExtractor,
        clock: Clock,
        usage_limits: UsageLimitService | None = None,
    ) -> None:
        self._sessions = session_factory
        self._cache = cache
        self._acquirer = acquirer
        self._extractor = extractor
        self._maintenance = CacheMaintenanceService(clock=clock)
        self._usage_limits = usage_limits

    def process(self, job_id: UUID) -> ProcessOutcome:
        with self._sessions.begin() as database:
            job = database.execute(
                select(ImportJob).where(ImportJob.id == job_id).with_for_update()
            ).scalar_one_or_none()
            if job is None:
                raise ValueError("import job does not exist")
            if job.status in {"ready", "needsReview"}:
                return ProcessOutcome.ALREADY_COMPLETED

            decision = self._cache.route(database, job_id=job_id)
            if decision.disposition == CacheDisposition.HIT:
                return ProcessOutcome.CACHE_HIT
            if decision.disposition == CacheDisposition.FOLLOWER:
                return ProcessOutcome.FOLLOWER
            if decision.disposition == CacheDisposition.RECHECK:
                return ProcessOutcome.RECHECK_REQUIRED
            if decision.disposition == CacheDisposition.BYPASS:
                return ProcessOutcome.BYPASS_REQUIRED
            if decision.claim is None:
                raise RuntimeError("leader decision did not include a claim")

            source = database.get(SourceVideo, decision.claim.source_video_id)
            if source is None:
                raise RuntimeError("source video disappeared during import")
            if self._usage_limits is not None:
                self._usage_limits.ensure_available(database)
            descriptor = SourceVideoDescriptor.from_stored(source)
            claim = decision.claim

        context = self._acquirer.acquire(descriptor, job_id=job_id)
        if not context.is_public:
            with self._sessions.begin() as database:
                self._maintenance.mark_private_or_deleted(
                    database,
                    source_video_id=descriptor.source_video_id,
                )
            raise ValueError("source is private or deleted")
        template = self._extractor.extract(context, job_id=job_id)

        with self._sessions.begin() as database:
            self._maintenance.confirm_public(
                database,
                source_video_id=descriptor.source_video_id,
            )
            self._cache.complete_shared(
                database,
                claim=claim,
                template=template,
                contract_version=self._extractor.contract_version,
                prompt_version=self._extractor.prompt_version,
                model_id=self._extractor.model_id,
            )
        return ProcessOutcome.COMPLETED
