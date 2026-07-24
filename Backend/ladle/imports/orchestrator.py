from enum import StrEnum
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderTransientError,
    ProviderUnavailable,
)
from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.acquisition.protocol import VideoAcquirer
from ladle.cache.maintenance import CacheMaintenanceService
from ladle.cache.service import CacheDisposition, ExtractionCacheService
from ladle.clock import Clock
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import ImportJob, SourceVideo
from ladle.extraction.claude import ExtractionUnavailable
from ladle.extraction.protocol import RecipeExtractor
from ladle.imports.transitions import ImportTransitionService
from ladle.recipes.template_clone import RecipeTemplateCloner
from ladle.usage.limits import UsageLimitService


class ProcessOutcome(StrEnum):
    COMPLETED = "completed"
    CACHE_HIT = "cacheHit"
    FOLLOWER = "follower"
    ALREADY_COMPLETED = "alreadyCompleted"
    RECHECK_REQUIRED = "recheckRequired"
    BYPASS_REQUIRED = "bypassRequired"
    PRIVATE_COMPLETED = "privateCompleted"
    PRIVATE_NEEDS_REVIEW = "privateNeedsReview"
    FAILED = "failed"


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
        private_text: PrivateTextCipher | None = None,
        private_completion: RecipeTemplateCloner | None = None,
        transitions: ImportTransitionService | None = None,
    ) -> None:
        self._sessions = session_factory
        self._cache = cache
        self._acquirer = acquirer
        self._extractor = extractor
        self._maintenance = CacheMaintenanceService(clock=clock)
        self._usage_limits = usage_limits
        self._private_text = private_text
        self._private_completion = private_completion
        self._transitions = transitions

    def process(self, job_id: UUID) -> ProcessOutcome:
        requires_recheck = False
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
                requires_recheck = True
            if decision.disposition == CacheDisposition.NEGATIVE:
                if self._transitions is None or job.source_video_id is None:
                    return ProcessOutcome.FAILED
                self._transitions.fail(
                    database,
                    job_id=job.id,
                    source_video_id=job.source_video_id,
                    failure_reason="privateOrDeleted",
                    diagnostic_code="negativeCacheHit",
                    include_shared_followers=False,
                )
                return ProcessOutcome.FAILED
            bypass_cache = decision.disposition == CacheDisposition.BYPASS
            if bypass_cache and (
                self._private_text is None or self._private_completion is None
            ):
                return ProcessOutcome.BYPASS_REQUIRED
            if not requires_recheck and not bypass_cache and decision.claim is None:
                raise RuntimeError("leader decision did not include a claim")

            source = database.get(SourceVideo, job.source_video_id)
            if source is None:
                raise RuntimeError("source video disappeared during import")
            if self._usage_limits is not None:
                self._usage_limits.ensure_available(database)
            descriptor = SourceVideoDescriptor.from_stored(source)
            claim = decision.claim
            correction_encrypted = job.correction_notes_encrypted
            pasted_encrypted = job.pasted_text_encrypted

        if requires_recheck:
            try:
                is_public = self._acquirer.check_public(descriptor, job_id=job_id)
            except ProviderUnavailable as error:
                if self._transitions is None:
                    raise
                self._fail_terminal(
                    job_id=job_id,
                    descriptor=descriptor,
                    claim=None,
                    bypass_cache=False,
                    error=error,
                )
                return ProcessOutcome.FAILED
            if not is_public:
                if self._transitions is None:
                    raise PrivateOrDeleted
                self._fail_terminal(
                    job_id=job_id,
                    descriptor=descriptor,
                    claim=None,
                    bypass_cache=False,
                    error=PrivateOrDeleted(),
                )
                return ProcessOutcome.FAILED
            with self._sessions.begin() as database:
                self._maintenance.confirm_public(
                    database,
                    source_video_id=descriptor.source_video_id,
                )
            return self.process(job_id)

        try:
            if bypass_cache and pasted_encrypted is not None:
                assert self._private_text is not None
                context = AcquiredVideoContext(
                    source=descriptor,
                    is_public=True,
                    title=None,
                    description="",
                    transcript=[
                        TextEvidence(
                            text=self._private_text.decrypt(pasted_encrypted),
                            provenance="user-pasted-text",
                            generated=False,
                        )
                    ],
                    visual_observations=[],
                    diagnostics=["pastedTextRecovery"],
                )
            else:
                context = self._acquirer.acquire(descriptor, job_id=job_id)
            if not context.is_public:
                raise PrivateOrDeleted
            if bypass_cache and correction_encrypted is not None:
                assert self._private_text is not None
                context.transcript.append(
                    TextEvidence(
                        text=self._private_text.decrypt(correction_encrypted),
                        provenance="user-correction-notes",
                        generated=False,
                    )
                )
            template = self._extractor.extract(context, job_id=job_id)
        except (
            ExtractionUnavailable,
            PrivateOrDeleted,
            ProviderUnavailable,
        ) as error:
            if self._transitions is None:
                raise
            self._fail_terminal(
                job_id=job_id,
                descriptor=descriptor,
                claim=claim,
                bypass_cache=bypass_cache,
                error=error,
            )
            return ProcessOutcome.FAILED

        with self._sessions.begin() as database:
            if bypass_cache:
                assert self._private_completion is not None
                job = database.execute(
                    select(ImportJob).where(ImportJob.id == job_id).with_for_update()
                ).scalar_one()
                promoted = self._private_completion.complete_private_for_job(
                    database,
                    job=job,
                    template=template,
                )
                return (
                    ProcessOutcome.PRIVATE_COMPLETED
                    if promoted
                    else ProcessOutcome.PRIVATE_NEEDS_REVIEW
                )
            self._maintenance.confirm_public(
                database,
                source_video_id=descriptor.source_video_id,
            )
            assert claim is not None
            self._cache.complete_shared(
                database,
                claim=claim,
                template=template,
                contract_version=self._extractor.contract_version,
                prompt_version=self._extractor.prompt_version,
                model_id=self._extractor.model_id,
            )
        return ProcessOutcome.COMPLETED

    def _fail_terminal(
        self,
        *,
        job_id: UUID,
        descriptor: SourceVideoDescriptor,
        claim: object,
        bypass_cache: bool,
        error: Exception,
    ) -> None:
        from ladle.cache.claims import ClaimLease

        if isinstance(error, PrivateOrDeleted):
            failure_reason = "privateOrDeleted"
        elif isinstance(error, ProviderTransientError):
            failure_reason = "networkUnavailable"
        else:
            failure_reason = "parserUnavailable"
        with self._sessions.begin() as database:
            if isinstance(error, PrivateOrDeleted):
                self._maintenance.mark_private_or_deleted(
                    database,
                    source_video_id=descriptor.source_video_id,
                )
            if isinstance(claim, ClaimLease):
                self._cache.abandon_claim(database, claim)
            assert self._transitions is not None
            self._transitions.fail(
                database,
                job_id=job_id,
                source_video_id=descriptor.source_video_id,
                failure_reason=failure_reason,
                diagnostic_code=type(error).__name__,
                include_shared_followers=not bypass_cache,
            )
