from dataclasses import dataclass
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.contracts.imports import ImportFailure, ImportJobResponse, ImportStatus
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import ImportJob, Recipe, SourceVideo
from ladle.imports.outbox import DispatchOutboxService
from ladle.imports.quotas import ImportQuotaService
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.recipes.limits import ensure_recipe_capacity, lock_recipe_capacity


class DuplicateRecipe(Exception):
    def __init__(self, existing_recipe_id: UUID) -> None:
        super().__init__("recipe already exists")
        self.existing_recipe_id = existing_recipe_id


class ImportJobNotFound(Exception):
    pass


class CurrentRecipeUnavailable(Exception):
    pass


@dataclass(frozen=True)
class AdmittedImport:
    job_id: UUID
    response: ImportJobResponse
    should_dispatch: bool


class AdmissionService:
    def __init__(
        self,
        *,
        parser: SourceIdentityParser,
        reservations: ReservationService,
        clock: Clock,
        private_text: PrivateTextCipher | None = None,
        quota: ImportQuotaService | None = None,
        outbox: DispatchOutboxService | None = None,
    ) -> None:
        self._parser = parser
        self._reservations = reservations
        self._clock = clock
        self._private_text = private_text
        self._quota = quota
        self._outbox = outbox

    def admit(
        self,
        database: Session,
        *,
        job_id: UUID,
        user_id: UUID,
        source_url: str,
        allow_duplicate: bool,
        idempotency_key: str,
        current_recipe_id: UUID | None = None,
        correction_notes: str | None = None,
        pasted_text: str | None = None,
    ) -> AdmittedImport:
        existing = self._idempotent_job(
            database,
            user_id=user_id,
            job_id=job_id,
            idempotency_key=idempotency_key,
        )
        if existing is not None:
            return AdmittedImport(
                job_id=existing.id,
                response=self.response(existing),
                should_dispatch=(
                    self._outbox.ensure_dispatchable(database, existing)
                    if self._outbox is not None and existing.status == "parsing"
                    else False
                ),
            )

        identity = self._parser.parse(source_url)
        current_recipe: Recipe | None = None
        if current_recipe_id is None:
            ensure_recipe_capacity(database, user_id)
        else:
            lock_recipe_capacity(database, user_id)
            current_recipe = database.scalar(
                select(Recipe)
                .where(
                    Recipe.id == current_recipe_id,
                    Recipe.user_id == user_id,
                    Recipe.deleted_at.is_(None),
                )
                .with_for_update()
            )
            if current_recipe is None:
                raise CurrentRecipeUnavailable

        existing = self._idempotent_job(
            database,
            user_id=user_id,
            job_id=job_id,
            idempotency_key=idempotency_key,
        )
        if existing is not None:
            return AdmittedImport(
                job_id=existing.id,
                response=self.response(existing),
                should_dispatch=(
                    self._outbox.ensure_dispatchable(database, existing)
                    if self._outbox is not None and existing.status == "parsing"
                    else False
                ),
            )

        source_video_id = database.scalar(
            insert(SourceVideo)
            .values(
                id=uuid4(),
                platform=identity.platform.value,
                platform_video_id=identity.platform_video_id,
                canonical_url=identity.canonical_url,
                source_revision="1",
                source_metadata={},
                created_at=self._clock.now(),
            )
            .on_conflict_do_nothing(
                index_elements=[
                    SourceVideo.platform,
                    SourceVideo.platform_video_id,
                ]
            )
            .returning(SourceVideo.id)
        )
        if source_video_id is None:
            source_video_id = database.scalar(
                select(SourceVideo.id).where(
                    SourceVideo.platform == identity.platform.value,
                    SourceVideo.platform_video_id == identity.platform_video_id,
                )
            )
        if source_video_id is None:
            raise RuntimeError("source video upsert failed")

        duplicate = database.scalar(
            select(Recipe.id).where(
                Recipe.user_id == user_id,
                Recipe.source_video_id == source_video_id,
                Recipe.deleted_at.is_(None),
            )
        )
        if duplicate is not None and not allow_duplicate:
            raise DuplicateRecipe(duplicate)

        now = self._clock.now()
        job = ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_video_id,
            source_url=source_url,
            canonical_url=identity.canonical_url,
            source=identity.platform.value,
            status="parsing",
            stage="admitted",
            retry_count=0,
            bypass_cache=bool(correction_notes or pasted_text),
            correction_notes_encrypted=self._encrypt(correction_notes),
            pasted_text_encrypted=self._encrypt(pasted_text),
            current_recipe_id=current_recipe_id,
            base_recipe_revision=(
                current_recipe.revision if current_recipe is not None else None
            ),
            idempotency_key=idempotency_key,
            created_at=now,
            updated_at=now,
        )
        database.add(job)
        database.flush()
        if self._quota is not None:
            self._quota.consume(
                database,
                user_id=user_id,
                import_job_id=job.id,
                operation="submit",
                event_key=f"{job.id}:submit",
            )
        if current_recipe_id is None:
            self._reservations.reserve(
                database,
                reservation_id=uuid4(),
                user_id=user_id,
                import_job_id=job.id,
            )
        if self._outbox is not None:
            self._outbox.queue(database, job.id)
        return AdmittedImport(
            job_id=job.id,
            response=self.response(job),
            should_dispatch=True,
        )

    def _encrypt(self, value: str | None) -> bytes | None:
        if value is None:
            return None
        if self._private_text is None:
            raise RuntimeError("private text cipher is unavailable")
        return self._private_text.encrypt(value)

    def get(
        self,
        database: Session,
        *,
        user_id: UUID,
        job_id: UUID,
    ) -> ImportJob:
        job = database.scalar(
            select(ImportJob).where(
                ImportJob.id == job_id,
                ImportJob.user_id == user_id,
            )
        )
        if job is None:
            raise ImportJobNotFound
        return job

    def response(self, job: ImportJob) -> ImportJobResponse:
        status = ImportStatus(job.status)
        failure = (
            ImportFailure(job.failure_reason)
            if job.failure_reason is not None
            else None
        )
        if status == ImportStatus.NEEDS_REVIEW:
            recipe_id = job.candidate_recipe_id or job.current_recipe_id
        elif status == ImportStatus.READY:
            recipe_id = job.current_recipe_id
        else:
            recipe_id = None
        return ImportJobResponse(
            job_id=job.id,
            status=status,
            failure_reason=failure,
            recipe_id=recipe_id,
            retry_count=job.retry_count,
            created_at=job.created_at,
            updated_at=job.updated_at,
        )

    def _idempotent_job(
        self,
        database: Session,
        *,
        user_id: UUID,
        job_id: UUID,
        idempotency_key: str,
    ) -> ImportJob | None:
        return database.scalar(
            select(ImportJob).where(
                ImportJob.user_id == user_id,
                (
                    (ImportJob.id == job_id)
                    | (ImportJob.idempotency_key == idempotency_key)
                ),
            )
        )
