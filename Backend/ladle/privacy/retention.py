from dataclasses import dataclass
from datetime import UTC, timedelta
from typing import Any, Protocol, cast
from uuid import UUID

from sqlalchemy import delete, func, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.engine import CursorResult
from sqlalchemy.orm import Session, aliased
from sqlalchemy.sql.base import Executable

from ladle.clock import Clock
from ladle.db.models import (
    AccountDeletionAudit,
    AppAttestChallenge,
    AuthSession,
    ExtractionCache,
    ImportJob,
    ImportQuotaEvent,
    NegativeExtractionCache,
    ObjectDeletionQueue,
    ProviderAttempt,
    Recipe,
    RecipeChange,
    UserSyncState,
)

RETENTION_SWEEP_TASK = "ladle.privacy.sweep"


class ObjectCleaner(Protocol):
    def delete(self, key: str) -> None: ...


@dataclass(frozen=True)
class RetentionPolicy:
    expired_session_days: int
    terminal_import_days: int
    private_text_hours: int
    provider_attempt_days: int
    sync_history_days: int
    invalid_cache_days: int
    deletion_audit_days: int


@dataclass(frozen=True)
class RetentionOutcome:
    expired_sessions: int = 0
    terminal_import_jobs: int = 0
    quota_events: int = 0
    private_text_fields: int = 0
    provider_attempts: int = 0
    expired_challenges: int = 0
    expired_negative_caches: int = 0
    invalid_caches: int = 0
    sync_changes: int = 0
    recipe_tombstones: int = 0
    deletion_audits: int = 0


class RetentionService:
    def __init__(self, *, clock: Clock, policy: RetentionPolicy) -> None:
        self._clock = clock
        self._policy = policy

    def sweep(self, database: Session) -> RetentionOutcome:
        now = self._clock.now()
        expired_sessions = _delete_count(
            database,
            delete(AuthSession).where(
                or_(
                    AuthSession.expires_at
                    <= now - timedelta(days=self._policy.expired_session_days),
                    AuthSession.revoked_at
                    <= now - timedelta(days=self._policy.expired_session_days),
                )
            ),
        )
        expired_challenges = _delete_count(
            database,
            delete(AppAttestChallenge).where(AppAttestChallenge.expires_at <= now),
        )
        expired_negative_caches = _delete_count(
            database,
            delete(NegativeExtractionCache).where(
                NegativeExtractionCache.expires_at <= now
            ),
        )
        terminal_import_jobs = _delete_count(
            database,
            delete(ImportJob).where(
                ImportJob.status.in_(("ready", "needsReview", "failed")),
                ImportJob.completed_at
                <= now - timedelta(days=self._policy.terminal_import_days),
            ),
        )
        # Quota events deliberately outlive their job (the FK sets NULL on
        # job deletion) because the monthly window can outlast the job's own
        # retention. Once the calendar month they were counted in has
        # passed, ImportQuotaService can never read them again — computed
        # the same way consume() computes month_start, so the two agree.
        month_start = (
            now.astimezone(UTC)
            .replace(hour=0, minute=0, second=0, microsecond=0)
            .replace(day=1)
        )
        quota_events = _delete_count(
            database,
            delete(ImportQuotaEvent).where(ImportQuotaEvent.occurred_at < month_start),
        )
        private_cutoff = now - timedelta(hours=self._policy.private_text_hours)
        private_jobs = list(
            database.scalars(
                select(ImportJob).where(
                    ImportJob.status.in_(("ready", "needsReview", "failed")),
                    ImportJob.completed_at <= private_cutoff,
                    or_(
                        ImportJob.correction_notes_encrypted.is_not(None),
                        ImportJob.pasted_text_encrypted.is_not(None),
                    ),
                )
            )
        )
        private_text_fields = 0
        for job in private_jobs:
            private_text_fields += int(job.correction_notes_encrypted is not None)
            private_text_fields += int(job.pasted_text_encrypted is not None)
            job.correction_notes_encrypted = None
            job.pasted_text_encrypted = None

        provider_attempts = _delete_count(
            database,
            delete(ProviderAttempt).where(
                func.coalesce(
                    ProviderAttempt.completed_at,
                    ProviderAttempt.created_at,
                )
                <= now - timedelta(days=self._policy.provider_attempt_days)
            ),
        )
        invalid_caches = self._purge_invalid_caches(database)
        sync_changes, recipe_tombstones = self._prune_sync_history(database)
        deletion_audits = _delete_count(
            database,
            delete(AccountDeletionAudit).where(
                AccountDeletionAudit.updated_at
                <= now - timedelta(days=self._policy.deletion_audit_days)
            ),
        )
        return RetentionOutcome(
            expired_sessions=expired_sessions,
            terminal_import_jobs=terminal_import_jobs,
            quota_events=quota_events,
            private_text_fields=private_text_fields,
            provider_attempts=provider_attempts,
            expired_challenges=expired_challenges,
            expired_negative_caches=expired_negative_caches,
            invalid_caches=invalid_caches,
            sync_changes=sync_changes,
            recipe_tombstones=recipe_tombstones,
            deletion_audits=deletion_audits,
        )

    def _purge_invalid_caches(self, database: Session) -> int:
        cutoff = self._clock.now() - timedelta(days=self._policy.invalid_cache_days)
        entries = list(
            database.scalars(
                select(ExtractionCache).where(
                    ExtractionCache.invalidated_at <= cutoff,
                    ~select(Recipe.id)
                    .where(Recipe.source_cache_id == ExtractionCache.id)
                    .exists(),
                )
            )
        )
        for entry in entries:
            if entry.thumbnail_object_key is not None:
                database.execute(
                    insert(ObjectDeletionQueue)
                    .values(
                        object_key=entry.thumbnail_object_key,
                        reason="invalidCache",
                        available_at=self._clock.now(),
                    )
                    .on_conflict_do_nothing(
                        index_elements=[ObjectDeletionQueue.object_key]
                    )
                )
            database.delete(entry)
        return len(entries)

    def _prune_sync_history(self, database: Session) -> tuple[int, int]:
        cutoff = self._clock.now() - timedelta(days=self._policy.sync_history_days)
        tombstones = list(
            database.scalars(
                select(Recipe).where(
                    Recipe.deleted_at.is_not(None),
                    Recipe.deleted_at <= cutoff,
                )
            )
        )
        tombstone_ids = [recipe.id for recipe in tombstones]
        changes = list(
            database.scalars(
                select(RecipeChange).where(RecipeChange.changed_at <= cutoff)
            )
        )
        newest = aliased(RecipeChange)
        removable: list[RecipeChange] = []
        for change in changes:
            if (
                change.recipe_id in tombstone_ids
                or database.scalar(
                    select(newest.sequence).where(
                        newest.user_id == change.user_id,
                        newest.recipe_id == change.recipe_id,
                        newest.sequence > change.sequence,
                    )
                )
                is not None
            ):
                removable.append(change)

        floors: dict[UUID, int] = {}
        for change in removable:
            floors[change.user_id] = max(
                floors.get(change.user_id, 1),
                change.sequence + 1,
            )
        for user_id, floor in floors.items():
            state = database.get(UserSyncState, user_id)
            if state is not None:
                state.minimum_retained_sequence = max(
                    state.minimum_retained_sequence,
                    floor,
                )
        for change in removable:
            database.delete(change)
        database.flush()
        for recipe in tombstones:
            database.delete(recipe)
        return len(removable), len(tombstones)


class ObjectDeletionProcessor:
    def __init__(
        self,
        *,
        clock: Clock,
        maximum_attempts: int,
        batch_size: int = 100,
    ) -> None:
        self._clock = clock
        self._maximum_attempts = maximum_attempts
        self._batch_size = batch_size

    def process(self, database: Session, *, storage: ObjectCleaner) -> int:
        now = self._clock.now()
        entries = list(
            database.scalars(
                select(ObjectDeletionQueue)
                .where(
                    ObjectDeletionQueue.deleted_at.is_(None),
                    ObjectDeletionQueue.available_at <= now,
                    ObjectDeletionQueue.attempts < self._maximum_attempts,
                )
                .order_by(ObjectDeletionQueue.available_at)
                .limit(self._batch_size)
                .with_for_update(skip_locked=True)
            )
        )
        deleted = 0
        for entry in entries:
            try:
                storage.delete(entry.object_key)
            except Exception as error:
                entry.attempts += 1
                entry.last_error = type(error).__name__[:128]
                delay_minutes = min(24 * 60, 2 ** min(entry.attempts, 10))
                entry.available_at = now + timedelta(minutes=delay_minutes)
            else:
                entry.attempts += 1
                entry.last_error = None
                entry.deleted_at = now
                deleted += 1
        return deleted


def _delete_count(database: Session, statement: Executable) -> int:
    result = cast(CursorResult[Any], database.execute(statement))
    return int(result.rowcount or 0)
