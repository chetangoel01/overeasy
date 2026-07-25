from dataclasses import dataclass
from datetime import timedelta
from enum import StrEnum
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.cache.claims import (
    ClaimLease,
    ClaimLost,
    ClaimRole,
    ExtractionClaimService,
)
from ladle.clock import Clock
from ladle.db.models import (
    ExtractionCache,
    ImportJob,
    NegativeExtractionCache,
    SourceVideo,
)
from ladle.observability.metrics import MetricsRegistry
from ladle.recipes.template_clone import RecipeTemplate, RecipeTemplateCloner


class CacheDisposition(StrEnum):
    HIT = "hit"
    LEADER = "leader"
    FOLLOWER = "follower"
    BYPASS = "bypass"
    RECHECK = "recheck"
    NEGATIVE = "negative"


class ImportJobUnavailable(Exception):
    pass


@dataclass(frozen=True)
class CacheDecision:
    disposition: CacheDisposition
    job_id: UUID
    claim: ClaimLease | None = None
    cache_entry_id: UUID | None = None
    recipe_id: UUID | None = None


@dataclass(frozen=True)
class CacheCompletion:
    cache_entry_id: UUID
    job_ids: tuple[UUID, ...]


class ExtractionCacheService:
    def __init__(
        self,
        *,
        clock: Clock,
        claims: ExtractionClaimService,
        cloner: RecipeTemplateCloner,
        public_recheck_after: timedelta,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._clock = clock
        self._claims = claims
        self._cloner = cloner
        self._public_recheck_after = public_recheck_after
        self._metrics = metrics

    def route(
        self,
        database: Session,
        *,
        job_id: UUID,
        contract_version: str,
        prompt_version: str,
        model_id: str,
    ) -> CacheDecision:
        job = database.execute(
            select(ImportJob).where(ImportJob.id == job_id).with_for_update()
        ).scalar_one_or_none()
        if job is None or job.source_video_id is None:
            raise ImportJobUnavailable
        if job.bypass_cache:
            return self._decision(CacheDisposition.BYPASS, job.id)
        if job.status in {"ready", "needsReview"}:
            return self._decision(
                CacheDisposition.HIT,
                job.id,
                cache_entry_id=job.cache_entry_id,
                recipe_id=job.current_recipe_id,
            )

        source = database.get(SourceVideo, job.source_video_id)
        if source is None:
            raise ImportJobUnavailable
        # Keyed exactly as `complete` writes it. Matching on the source alone
        # served a template produced by whatever prompt and model happened to
        # run first, so bumping PROMPT_VERSION changed nothing for any video
        # already imported: the old entry answered, extraction never ran, and
        # no entry under the new version was ever written.
        entry = database.scalar(
            select(ExtractionCache)
            .where(
                ExtractionCache.source_video_id == source.id,
                ExtractionCache.source_revision == source.source_revision,
                ExtractionCache.contract_version == contract_version,
                ExtractionCache.prompt_version == prompt_version,
                ExtractionCache.model_id == model_id,
                ExtractionCache.invalidated_at.is_(None),
            )
            .order_by(ExtractionCache.created_at.desc(), ExtractionCache.id)
            .limit(1)
        )
        if entry is not None:
            confirmed_at = source.public_access_confirmed_at
            if (
                confirmed_at is None
                or confirmed_at <= self._clock.now() - self._public_recheck_after
            ):
                job.stage = "publicRecheck"
                job.updated_at = self._clock.now()
                return self._decision(
                    CacheDisposition.RECHECK,
                    job.id,
                    cache_entry_id=entry.id,
                )
            template = RecipeTemplate.model_validate(entry.template_json)
            recipe_id = self._cloner.clone_for_job(
                database,
                job=job,
                cache_entry=entry,
                template=template,
            )
            return self._decision(
                CacheDisposition.HIT,
                job.id,
                cache_entry_id=entry.id,
                recipe_id=recipe_id,
            )

        negative = database.scalar(
            select(NegativeExtractionCache).where(
                NegativeExtractionCache.source_video_id == source.id,
                NegativeExtractionCache.expires_at > self._clock.now(),
            )
        )
        if negative is not None:
            return self._decision(CacheDisposition.NEGATIVE, job.id)

        claim = self._claims.acquire(
            database,
            source_video_id=source.id,
            job_id=job.id,
        )
        disposition = (
            CacheDisposition.LEADER
            if claim.role == ClaimRole.LEADER
            else CacheDisposition.FOLLOWER
        )
        job.stage = (
            "extracting" if disposition == CacheDisposition.LEADER else "waiting"
        )
        job.updated_at = self._clock.now()
        return self._decision(disposition, job.id, claim=claim)

    def _decision(
        self,
        disposition: CacheDisposition,
        job_id: UUID,
        *,
        claim: ClaimLease | None = None,
        cache_entry_id: UUID | None = None,
        recipe_id: UUID | None = None,
    ) -> CacheDecision:
        if self._metrics is not None:
            self._metrics.record_cache(disposition.value)
        return CacheDecision(
            disposition=disposition,
            job_id=job_id,
            claim=claim,
            cache_entry_id=cache_entry_id,
            recipe_id=recipe_id,
        )

    def complete_shared(
        self,
        database: Session,
        *,
        claim: ClaimLease,
        template: RecipeTemplate,
        contract_version: str,
        prompt_version: str,
        model_id: str,
        thumbnail_object_key: str | None = None,
    ) -> CacheCompletion:
        self._claims.assert_leader(database, claim, require_live=True)
        source = database.get(SourceVideo, claim.source_video_id)
        if source is None:
            raise ImportJobUnavailable

        entry = database.scalar(
            select(ExtractionCache).where(
                ExtractionCache.source_video_id == source.id,
                ExtractionCache.source_revision == source.source_revision,
                ExtractionCache.contract_version == contract_version,
                ExtractionCache.prompt_version == prompt_version,
                ExtractionCache.model_id == model_id,
            )
        )
        if entry is None:
            entry = ExtractionCache(
                id=uuid4(),
                source_video_id=source.id,
                source_revision=source.source_revision,
                contract_version=contract_version,
                prompt_version=prompt_version,
                model_id=model_id,
                template_json=template.model_dump(mode="json", by_alias=True),
                review_status=template.review_status.value,
                thumbnail_object_key=thumbnail_object_key,
                created_at=self._clock.now(),
            )
            database.add(entry)
            database.flush()
        elif entry.invalidated_at is not None:
            # A fresh extraction after invalidation refreshes the row in
            # place; the identity columns carry a unique constraint.
            entry.template_json = template.model_dump(mode="json", by_alias=True)
            entry.review_status = template.review_status.value
            entry.thumbnail_object_key = thumbnail_object_key
            entry.invalidated_at = None
            entry.created_at = self._clock.now()
            database.flush()
        elif entry.thumbnail_object_key is None and thumbnail_object_key is not None:
            entry.thumbnail_object_key = thumbnail_object_key
            database.flush()

        jobs = list(
            database.scalars(
                select(ImportJob)
                .where(
                    ImportJob.source_video_id == source.id,
                    ImportJob.status == "parsing",
                    ImportJob.bypass_cache.is_(False),
                )
                .order_by(ImportJob.created_at, ImportJob.id)
                .with_for_update()
            )
        )
        completed_job_ids = tuple(
            job.id
            for job in jobs
            if self._cloner.clone_for_job(
                database,
                job=job,
                cache_entry=entry,
                template=template,
            )
        )
        self._claims.release(database, claim)
        return CacheCompletion(cache_entry_id=entry.id, job_ids=completed_job_ids)

    def abandon_claim(self, database: Session, claim: ClaimLease) -> None:
        try:
            self._claims.release(database, claim)
        except ClaimLost:
            return
