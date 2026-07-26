from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from alembic import command
from ladle.db.models import (
    AccountDeletionAudit,
    AppAttestChallenge,
    AuthSession,
    Device,
    ExtractionCache,
    ImportJob,
    NegativeExtractionCache,
    ObjectDeletionQueue,
    ProviderAttempt,
    Recipe,
    RecipeChange,
    SourceVideo,
    User,
    UserSyncState,
)
from ladle.db.session import build_engine
from ladle.privacy.retention import (
    ObjectDeletionProcessor,
    RetentionPolicy,
    RetentionService,
)
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


class RecordingStorage:
    def __init__(self) -> None:
        self.deleted: list[str] = []

    def delete(self, key: str) -> None:
        self.deleted.append(key)


@pytest.mark.integration
def test_retention_removes_expired_private_operational_data_and_queues_objects(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    now = datetime(2026, 7, 26, 12, 0, tzinfo=UTC)
    old = now - timedelta(days=500)
    recent = now - timedelta(days=1)
    user_id = uuid4()
    source_id = uuid4()
    old_cache_id = uuid4()
    retained_cache_id = uuid4()
    old_job_id = uuid4()
    recent_job_id = uuid4()
    old_recipe_id = uuid4()
    active_recipe_id = uuid4()
    with Session(engine) as database, database.begin():
        database.add(User(id=user_id, kind="guest", created_at=old))
        database.flush()
        device_id = uuid4()
        database.add(
            Device(
                id=device_id,
                user_id=user_id,
                installation_id="retention-installation",
                created_at=old,
                last_seen_at=recent,
            )
        )
        database.flush()
        database.add_all(
            [
                AuthSession(
                    id=uuid4(),
                    user_id=user_id,
                    device_id=device_id,
                    token_family_id=uuid4(),
                    refresh_token_hash=b"a" * 32,
                    expires_at=old,
                    created_at=old,
                ),
                AuthSession(
                    id=uuid4(),
                    user_id=user_id,
                    device_id=device_id,
                    token_family_id=uuid4(),
                    refresh_token_hash=b"b" * 32,
                    expires_at=now + timedelta(days=5),
                    created_at=recent,
                ),
                AppAttestChallenge(
                    id=uuid4(),
                    installation_id="retention-installation",
                    purpose="importSubmission",
                    challenge_hash=b"c" * 32,
                    created_at=old,
                    expires_at=old,
                ),
                SourceVideo(
                    id=source_id,
                    platform="youtube",
                    platform_video_id="retention-source",
                    canonical_url="https://www.youtube.com/watch?v=retention",
                    source_revision="1",
                    source_metadata={},
                    created_at=old,
                ),
            ]
        )
        database.flush()
        database.add_all(
            [
                ExtractionCache(
                    id=old_cache_id,
                    source_video_id=source_id,
                    source_revision="old",
                    contract_version="v1",
                    prompt_version="v1",
                    model_id="model",
                    template_json={},
                    review_status="ready",
                    thumbnail_object_key="thumbnails/old.webp",
                    created_at=old,
                    invalidated_at=old,
                ),
                ExtractionCache(
                    id=retained_cache_id,
                    source_video_id=source_id,
                    source_revision="current",
                    contract_version="v1",
                    prompt_version="v1",
                    model_id="model",
                    template_json={},
                    review_status="ready",
                    thumbnail_object_key="thumbnails/current.webp",
                    created_at=recent,
                ),
                NegativeExtractionCache(
                    id=uuid4(),
                    source_video_id=source_id,
                    reason="parserUnavailable",
                    created_at=old,
                    expires_at=old,
                ),
            ]
        )
        database.flush()
        for job_id, stamp, key in (
            (old_job_id, old, "old-import"),
            (recent_job_id, recent, "recent-import"),
        ):
            database.add(
                ImportJob(
                    id=job_id,
                    user_id=user_id,
                    source_video_id=source_id,
                    source_url="https://youtu.be/retention",
                    canonical_url="https://www.youtube.com/watch?v=retention",
                    source="youtube",
                    status="failed",
                    stage="failed",
                    failure_reason="parserUnavailable",
                    retry_count=0,
                    bypass_cache=False,
                    correction_notes_encrypted=b"private-correction",
                    pasted_text_encrypted=b"private-paste",
                    idempotency_key=key,
                    created_at=stamp,
                    updated_at=stamp,
                    completed_at=stamp,
                )
            )
        database.flush()
        database.add(
            ProviderAttempt(
                id=uuid4(),
                import_job_id=recent_job_id,
                provider="test",
                operation="extract",
                idempotency_key="old-attempt",
                status="succeeded",
                billed_units=Decimal("1"),
                created_at=old,
                completed_at=old,
            )
        )
        database.add_all(
            [
                Recipe(
                    id=old_recipe_id,
                    user_id=user_id,
                    title="Old tombstone",
                    description="",
                    source="other",
                    original_url="https://example.test/old",
                    servings=Decimal("1"),
                    review_status="ready",
                    deleted_at=old,
                    revision=2,
                    created_at=old,
                    updated_at=old,
                ),
                Recipe(
                    id=active_recipe_id,
                    user_id=user_id,
                    source_cache_id=retained_cache_id,
                    title="Current",
                    description="",
                    source="other",
                    original_url="https://example.test/current",
                    servings=Decimal("1"),
                    review_status="ready",
                    revision=2,
                    created_at=old,
                    updated_at=recent,
                ),
                UserSyncState(
                    user_id=user_id,
                    next_sequence=5,
                    minimum_retained_sequence=1,
                ),
            ]
        )
        database.flush()
        database.add_all(
            [
                RecipeChange(
                    user_id=user_id,
                    sequence=1,
                    recipe_id=active_recipe_id,
                    kind="upsert",
                    recipe_revision=1,
                    changed_at=old,
                ),
                RecipeChange(
                    user_id=user_id,
                    sequence=2,
                    recipe_id=old_recipe_id,
                    kind="upsert",
                    recipe_revision=1,
                    changed_at=old,
                ),
                RecipeChange(
                    user_id=user_id,
                    sequence=3,
                    recipe_id=old_recipe_id,
                    kind="delete",
                    recipe_revision=2,
                    changed_at=old,
                ),
                RecipeChange(
                    user_id=user_id,
                    sequence=4,
                    recipe_id=active_recipe_id,
                    kind="upsert",
                    recipe_revision=2,
                    changed_at=recent,
                ),
                AccountDeletionAudit(
                    id=uuid4(),
                    user_digest=b"d" * 32,
                    idempotency_digest=b"e" * 32,
                    account_kind="guest",
                    status="completed",
                    created_at=old,
                    updated_at=old,
                    completed_at=old,
                ),
            ]
        )

    policy = RetentionPolicy(
        expired_session_days=7,
        terminal_import_days=30,
        private_text_hours=24,
        provider_attempt_days=30,
        sync_history_days=365,
        invalid_cache_days=30,
        deletion_audit_days=365,
    )
    with Session(engine) as database, database.begin():
        outcome = RetentionService(clock=FrozenClock(now), policy=policy).sweep(
            database
        )

    assert outcome.expired_sessions == 1
    assert outcome.terminal_import_jobs == 1
    assert outcome.private_text_fields == 2
    assert outcome.provider_attempts == 1
    assert outcome.expired_challenges == 1
    assert outcome.expired_negative_caches == 1
    assert outcome.invalid_caches == 1
    assert outcome.sync_changes == 3
    assert outcome.recipe_tombstones == 1
    assert outcome.deletion_audits == 1

    with Session(engine) as database:
        assert database.get(ImportJob, old_job_id) is None
        retained_job = database.get(ImportJob, recent_job_id)
        assert retained_job is not None
        assert retained_job.pasted_text_encrypted is None
        assert retained_job.correction_notes_encrypted is None
        assert database.get(ExtractionCache, old_cache_id) is None
        assert database.get(ExtractionCache, retained_cache_id) is not None
        assert database.get(Recipe, old_recipe_id) is None
        assert database.get(Recipe, active_recipe_id) is not None
        assert database.scalar(select(func.count()).select_from(RecipeChange)) == 1
        sync_state = database.get(UserSyncState, user_id)
        assert sync_state is not None and sync_state.minimum_retained_sequence == 4
        queued = database.get(ObjectDeletionQueue, "thumbnails/old.webp")
        assert queued is not None and queued.reason == "invalidCache"

    storage = RecordingStorage()
    with Session(engine) as database, database.begin():
        deleted = ObjectDeletionProcessor(
            clock=FrozenClock(now),
            maximum_attempts=8,
        ).process(database, storage=storage)
    assert deleted == 1
    assert storage.deleted == ["thumbnails/old.webp"]

    engine.dispose()
