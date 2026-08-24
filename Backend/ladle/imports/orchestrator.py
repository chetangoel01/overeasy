from contextlib import AbstractContextManager, nullcontext
from enum import StrEnum
from typing import Protocol
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
from ladle.cache.claims import ClaimLease
from ladle.cache.maintenance import CacheMaintenanceService
from ladle.cache.service import CacheDisposition, ExtractionCacheService
from ladle.clock import Clock
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import ImportJob, SourceVideo
from ladle.extraction.claude import ExtractionUnavailable
from ladle.extraction.evidence_gate import (
    InsufficientTextEvidence,
    require_recipe_evidence,
)
from ladle.extraction.protocol import RecipeExtractor
from ladle.imports.thumbnails import OEmbedThumbnailFetcher, ThumbnailAsset
from ladle.imports.transitions import ImportTransitionService
from ladle.observability.metrics import MetricsRegistry
from ladle.observability.structured_logging import log_context
from ladle.recipes.template_clone import RecipeTemplateCloner
from ladle.usage.limits import UsageLimitExceeded


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


class ClaimHeartbeat(Protocol):
    def monitor(self, claim: ClaimLease) -> AbstractContextManager[None]: ...


class ImportOrchestrator:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        cache: ExtractionCacheService,
        acquirer: VideoAcquirer,
        extractor: RecipeExtractor,
        clock: Clock,
        private_text: PrivateTextCipher | None = None,
        private_completion: RecipeTemplateCloner | None = None,
        transitions: ImportTransitionService | None = None,
        metrics: MetricsRegistry | None = None,
        thumbnails: OEmbedThumbnailFetcher | None = None,
        heartbeat: ClaimHeartbeat | None = None,
    ) -> None:
        self._sessions = session_factory
        self._cache = cache
        self._acquirer = acquirer
        self._extractor = extractor
        self._maintenance = CacheMaintenanceService(clock=clock)
        self._private_text = private_text
        self._private_completion = private_completion
        self._transitions = transitions
        self._metrics = metrics
        self._thumbnails = thumbnails
        self._heartbeat = heartbeat

    def process(self, job_id: UUID) -> ProcessOutcome:
        requires_recheck = False
        with self._sessions.begin() as database:
            job = database.execute(
                select(ImportJob).where(ImportJob.id == job_id).with_for_update()
            ).scalar_one_or_none()
            if job is None:
                raise ValueError("import job does not exist")
            if job.status in {"ready", "needsReview"}:
                return self._outcome(
                    ProcessOutcome.ALREADY_COMPLETED,
                    status=job.status,
                    source=job.source,
                )

            decision = self._cache.route(
                database,
                job_id=job_id,
                contract_version=self._extractor.contract_version,
                prompt_version=self._extractor.prompt_version,
                model_id=self._extractor.model_id,
            )
            if decision.disposition == CacheDisposition.HIT:
                return self._outcome(
                    ProcessOutcome.CACHE_HIT,
                    status=job.status,
                    source=job.source,
                )
            if decision.disposition == CacheDisposition.FOLLOWER:
                return self._outcome(
                    ProcessOutcome.FOLLOWER,
                    status="parsing",
                    source=job.source,
                )
            if decision.disposition == CacheDisposition.RECHECK:
                requires_recheck = True
            if decision.disposition == CacheDisposition.NEGATIVE:
                if self._transitions is None or job.source_video_id is None:
                    return self._outcome(
                        ProcessOutcome.FAILED,
                        status="failed",
                        source=job.source,
                    )
                self._transitions.fail(
                    database,
                    job_id=job.id,
                    source_video_id=job.source_video_id,
                    failure_reason="privateOrDeleted",
                    diagnostic_code="negativeCacheHit",
                    include_shared_followers=False,
                )
                return self._outcome(
                    ProcessOutcome.FAILED,
                    status="failed",
                    source=job.source,
                )
            bypass_cache = decision.disposition == CacheDisposition.BYPASS
            if bypass_cache and (
                self._private_text is None or self._private_completion is None
            ):
                return self._outcome(
                    ProcessOutcome.BYPASS_REQUIRED,
                    status="parsing",
                    source=job.source,
                )
            if not requires_recheck and not bypass_cache and decision.claim is None:
                raise RuntimeError("leader decision did not include a claim")

            source = database.get(SourceVideo, job.source_video_id)
            if source is None:
                raise RuntimeError("source video disappeared during import")
            descriptor = SourceVideoDescriptor.from_stored(source)
            claim = decision.claim
            correction_encrypted = job.correction_notes_encrypted
            pasted_encrypted = job.pasted_text_encrypted

        if requires_recheck:
            try:
                with log_context(stage="publicRecheck"):
                    is_public = self._acquirer.check_public(
                        descriptor,
                        job_id=job_id,
                    )
            except (ProviderUnavailable, UsageLimitExceeded) as error:
                if self._transitions is None:
                    raise
                self._fail_terminal(
                    job_id=job_id,
                    descriptor=descriptor,
                    claim=None,
                    bypass_cache=False,
                    error=error,
                )
                return self._outcome(
                    ProcessOutcome.FAILED,
                    status="failed",
                    source=descriptor.platform,
                )
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
                return self._outcome(
                    ProcessOutcome.FAILED,
                    status="failed",
                    source=descriptor.platform,
                )
            with self._sessions.begin() as database:
                self._maintenance.confirm_public(
                    database,
                    source_video_id=descriptor.source_video_id,
                )
            return self.process(job_id)

        monitor = (
            self._heartbeat.monitor(claim)
            if self._heartbeat is not None and isinstance(claim, ClaimLease)
            else nullcontext()
        )
        try:
            with monitor:
                with log_context(stage="acquisition"):
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
                require_recipe_evidence(context)
                thumbnail_asset: ThumbnailAsset | None = None
                with log_context(stage="thumbnailContext"):
                    if self._thumbnails is not None:
                        thumbnail_asset = self._thumbnails.download(
                            descriptor,
                            candidate_url=context.thumbnail_url,
                        )
                with log_context(stage="extraction"):
                    template = self._extractor.extract(context, job_id=job_id)
                with log_context(stage="thumbnail"):
                    thumbnail_key = (
                        self._thumbnails.store(
                            descriptor,
                            thumbnail_asset,
                        )
                        if (
                            self._thumbnails is not None
                            and thumbnail_asset is not None
                            and not bypass_cache
                        )
                        else None
                    )
                    thumbnail_remote_url = (
                        context.thumbnail_url
                        if self._thumbnails is None
                        and context.thumbnail_url is not None
                        and context.thumbnail_url.startswith("https://")
                        and not bypass_cache
                        else None
                    )
        except (
            ExtractionUnavailable,
            InsufficientTextEvidence,
            PrivateOrDeleted,
            ProviderUnavailable,
            UsageLimitExceeded,
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
            return self._outcome(
                ProcessOutcome.FAILED,
                status="failed",
                source=descriptor.platform,
            )

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
                return self._outcome(
                    (
                        ProcessOutcome.PRIVATE_COMPLETED
                        if promoted
                        else ProcessOutcome.PRIVATE_NEEDS_REVIEW
                    ),
                    status=job.status,
                    source=job.source,
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
                thumbnail_object_key=thumbnail_key,
                thumbnail_remote_url=thumbnail_remote_url,
            )
        return self._outcome(
            ProcessOutcome.COMPLETED,
            status=template.review_status.value,
            source=descriptor.platform,
        )

    def _outcome(
        self,
        outcome: ProcessOutcome,
        *,
        status: str,
        source: str,
    ) -> ProcessOutcome:
        if self._metrics is not None:
            self._metrics.record_job(status, source)
        return outcome

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
            diagnostic_code = type(error).__name__
        elif isinstance(error, InsufficientTextEvidence):
            failure_reason = "insufficientTextEvidence"
            diagnostic_code = "insufficientTextEvidence"
        elif isinstance(error, UsageLimitExceeded):
            failure_reason = "quotaExceeded"
            diagnostic_code = type(error).__name__
        elif isinstance(error, ProviderTransientError):
            failure_reason = "networkUnavailable"
            diagnostic_code = type(error).__name__
        else:
            failure_reason = "parserUnavailable"
            diagnostic_code = type(error).__name__
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
                diagnostic_code=diagnostic_code,
                include_shared_followers=not bypass_cache,
            )
