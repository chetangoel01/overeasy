from datetime import datetime
from decimal import Decimal
from typing import Any
from uuid import UUID, uuid4

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Float,
    ForeignKey,
    ForeignKeyConstraint,
    Index,
    Integer,
    LargeBinary,
    Numeric,
    String,
    Text,
    UniqueConstraint,
    Uuid,
    func,
    text,
)
from sqlalchemy.orm import Mapped, mapped_column

from ladle.db.base import Base


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(
            "kind IN ('guest', 'apple', 'google')",
            name="ck_users_kind",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    # Seeded from the provider on first sign-in and editable afterwards, so a
    # later sign-in must never overwrite it. Apple supplies a name exactly
    # once, which is why it is captured rather than fetched on demand.
    display_name: Mapped[str | None] = mapped_column(String(64), nullable=True)
    # The provider's own copy. No local edit to lose, so this may refresh.
    avatar_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    merged_into_user_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("users.id"), nullable=True
    )


class AccountDeletionAudit(Base):
    __tablename__ = "account_deletion_audits"
    __table_args__ = (
        CheckConstraint(
            "account_kind IN ('guest', 'apple', 'google')",
            name="ck_account_deletion_audits_kind",
        ),
        CheckConstraint(
            "status IN ('requested', 'revokingProvider', 'deleting', "
            "'completed', 'failed')",
            name="ck_account_deletion_audits_status",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_digest: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    idempotency_digest: Mapped[bytes] = mapped_column(
        LargeBinary(32), nullable=False, unique=True
    )
    account_kind: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    failure_code: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ObjectDeletionQueue(Base):
    __tablename__ = "object_deletion_queue"
    __table_args__ = (
        CheckConstraint(
            "attempts >= 0",
            name="ck_object_deletion_queue_attempts_nonnegative",
        ),
    )

    object_key: Mapped[str] = mapped_column(Text, primary_key=True)
    reason: Mapped[str] = mapped_column(String(64), nullable=False)
    available_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    attempts: Mapped[int] = mapped_column(Integer, nullable=False, server_default="0")
    last_error: Mapped[str | None] = mapped_column(String(128), nullable=True)
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class AppleIdentity(Base):
    __tablename__ = "apple_identities"
    __table_args__ = (UniqueConstraint("user_id", name="uq_apple_identities_user_id"),)

    apple_sub: Mapped[str] = mapped_column(String(255), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    refresh_token_encrypted: Mapped[bytes | None] = mapped_column(
        LargeBinary, nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class GoogleIdentity(Base):
    __tablename__ = "google_identities"
    __table_args__ = (UniqueConstraint("user_id", name="uq_google_identities_user_id"),)

    google_sub: Mapped[str] = mapped_column(String(255), primary_key=True)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class Device(Base):
    __tablename__ = "devices"

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    installation_id: Mapped[str] = mapped_column(
        String(255), nullable=False, unique=True
    )
    attestation_state: Mapped[str] = mapped_column(
        String(32), nullable=False, server_default="unverified"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    last_seen_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class AppAttestChallenge(Base):
    __tablename__ = "app_attest_challenges"
    __table_args__ = (
        CheckConstraint(
            "purpose IN ('guestCreation', 'importSubmission', 'importRetry')",
            name="ck_app_attest_challenges_purpose",
        ),
        Index("ix_app_attest_challenges_expires_at", "expires_at"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    installation_id: Mapped[str] = mapped_column(String(255), nullable=False)
    purpose: Mapped[str] = mapped_column(String(32), nullable=False)
    challenge_hash: Mapped[bytes] = mapped_column(LargeBinary(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    consumed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class AppAttestKey(Base):
    __tablename__ = "app_attest_keys"
    __table_args__ = (
        CheckConstraint(
            "environment IN ('development', 'production')",
            name="ck_app_attest_keys_environment",
        ),
        CheckConstraint(
            "status IN ('valid', 'revoked')",
            name="ck_app_attest_keys_status",
        ),
        Index("ix_app_attest_keys_installation_id", "installation_id"),
    )

    key_id: Mapped[str] = mapped_column(String(255), primary_key=True)
    installation_id: Mapped[str] = mapped_column(String(255), nullable=False)
    device_id: Mapped[UUID | None] = mapped_column(
        Uuid,
        ForeignKey("devices.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    public_key: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    receipt: Mapped[bytes] = mapped_column(LargeBinary, nullable=False)
    environment: Mapped[str] = mapped_column(String(16), nullable=False)
    assertion_counter: Mapped[int] = mapped_column(
        BigInteger, nullable=False, server_default="0"
    )
    status: Mapped[str] = mapped_column(
        String(16), nullable=False, server_default="valid"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    last_asserted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revocation_reason: Mapped[str | None] = mapped_column(String(128), nullable=True)


class AuthSession(Base):
    __tablename__ = "auth_sessions"

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    device_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("devices.id", ondelete="CASCADE"), nullable=False
    )
    token_family_id: Mapped[UUID] = mapped_column(Uuid, nullable=False, index=True)
    refresh_token_hash: Mapped[bytes] = mapped_column(
        LargeBinary(32), nullable=False, unique=True
    )
    previous_refresh_token_hash: Mapped[bytes | None] = mapped_column(
        LargeBinary(32), nullable=True
    )
    previous_valid_until: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    revoked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    rotated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class SourceVideo(Base):
    __tablename__ = "source_videos"
    __table_args__ = (
        # Migration 0019's partial index, restated so autogenerate keeps it.
        Index(
            "ix_source_videos_like_count",
            text("like_count DESC"),
            postgresql_where=text("like_count IS NOT NULL"),
        ),
        UniqueConstraint(
            "platform",
            "platform_video_id",
            name="uq_source_videos_platform_identity",
        ),
        CheckConstraint(
            "platform IN ('youtube', 'tiktok', 'instagram')",
            name="ck_source_videos_platform",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    platform: Mapped[str] = mapped_column(String(16), nullable=False)
    platform_video_id: Mapped[str] = mapped_column(String(255), nullable=False)
    canonical_url: Mapped[str] = mapped_column(Text, nullable=False)
    public_access_confirmed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    source_revision: Mapped[str] = mapped_column(
        String(255), nullable=False, server_default="1"
    )
    # Engagement counts as the source platform last reported them, with the
    # moment they were taken. A snapshot, never a live figure.
    like_count: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    view_count: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    comment_count: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    repost_count: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    published_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    counts_refreshed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    source_metadata: Mapped[dict[str, Any]] = mapped_column(
        "metadata_json", JSON, nullable=False, server_default=text("'{}'::json")
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    checked_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ExtractionCache(Base):
    __tablename__ = "extraction_cache"
    __table_args__ = (
        UniqueConstraint(
            "source_video_id",
            "source_revision",
            "contract_version",
            "prompt_version",
            "model_id",
            name="uq_extraction_cache_identity",
        ),
        CheckConstraint(
            "review_status IN ('ready', 'needsReview')",
            name="ck_extraction_cache_review_status",
        ),
        CheckConstraint(
            "thumbnail_object_key IS NULL OR thumbnail_remote_url IS NULL",
            name="ck_extraction_cache_one_thumbnail_location",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source_video_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("source_videos.id", ondelete="CASCADE"), nullable=False
    )
    source_revision: Mapped[str] = mapped_column(String(255), nullable=False)
    contract_version: Mapped[str] = mapped_column(String(64), nullable=False)
    prompt_version: Mapped[str] = mapped_column(String(64), nullable=False)
    model_id: Mapped[str] = mapped_column(String(128), nullable=False)
    template_json: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    review_status: Mapped[str] = mapped_column(String(24), nullable=False)
    thumbnail_object_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    thumbnail_remote_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    invalidated_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class NegativeExtractionCache(Base):
    __tablename__ = "negative_extraction_cache"
    __table_args__ = (
        CheckConstraint(
            "reason IN ('privateOrDeleted', 'parserUnavailable')",
            name="ck_negative_extraction_cache_reason",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source_video_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("source_videos.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    reason: Mapped[str] = mapped_column(String(32), nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )


class Recipe(Base):
    __tablename__ = "recipes"
    __table_args__ = (
        # Declared here as well as in migration 0018 so autogenerate does not
        # propose dropping them: the Discover feed groups and filters on
        # exactly these columns.
        Index("ix_recipes_source_video_id", "source_video_id"),
        Index(
            "ix_recipes_discover_ranking",
            "review_status",
            "source",
            "source_video_id",
            postgresql_where=text("deleted_at IS NULL AND source_cache_id IS NOT NULL"),
        ),
        CheckConstraint(
            "source IN ('tiktok', 'instagram', 'youtube', 'other')",
            name="ck_recipes_source",
        ),
        CheckConstraint(
            "review_status IN ('ready', 'needsReview')",
            name="ck_recipes_review_status",
        ),
        CheckConstraint("revision > 0", name="ck_recipes_revision_positive"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    source_video_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("source_videos.id"), nullable=True
    )
    source_cache_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("extraction_cache.id"), nullable=True
    )
    title: Mapped[str] = mapped_column(Text, nullable=False)
    description: Mapped[str] = mapped_column(Text, nullable=False, server_default="")
    notes: Mapped[list[str]] = mapped_column(
        JSON, nullable=False, default=list, server_default=text("'[]'::json")
    )
    creator_name: Mapped[str | None] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    original_url: Mapped[str] = mapped_column(Text, nullable=False)
    preparation_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    cooking_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    total_minutes: Mapped[int | None] = mapped_column(Integer, nullable=True)
    servings: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    favorite: Mapped[bool] = mapped_column(
        Boolean, nullable=False, server_default=text("false")
    )
    review_status: Mapped[str] = mapped_column(String(24), nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    revision: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class ImportJob(Base):
    __tablename__ = "import_jobs"
    __table_args__ = (
        UniqueConstraint(
            "user_id", "idempotency_key", name="uq_import_jobs_user_idempotency"
        ),
        CheckConstraint(
            "source IN ('tiktok', 'instagram', 'youtube', 'other')",
            name="ck_import_jobs_source",
        ),
        CheckConstraint(
            "status IN ('parsing', 'ready', 'needsReview', 'failed', 'cancelled')",
            name="ck_import_jobs_status",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    source_video_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("source_videos.id"), nullable=True
    )
    source_url: Mapped[str] = mapped_column(Text, nullable=False)
    canonical_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    source: Mapped[str] = mapped_column(String(16), nullable=False)
    status: Mapped[str] = mapped_column(
        String(24), nullable=False, server_default="parsing"
    )
    stage: Mapped[str] = mapped_column(
        String(32), nullable=False, server_default="admitted"
    )
    failure_reason: Mapped[str | None] = mapped_column(String(32), nullable=True)
    diagnostic_code: Mapped[str | None] = mapped_column(String(128), nullable=True)
    retry_count: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default="0"
    )
    bypass_cache: Mapped[bool] = mapped_column(
        Boolean, nullable=False, server_default=text("false")
    )
    correction_notes_encrypted: Mapped[bytes | None] = mapped_column(
        LargeBinary, nullable=True
    )
    pasted_text_encrypted: Mapped[bytes | None] = mapped_column(
        LargeBinary, nullable=True
    )
    current_recipe_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("recipes.id"), nullable=True
    )
    candidate_recipe_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("recipes.id"), nullable=True
    )
    cache_entry_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("extraction_cache.id"), nullable=True
    )
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    base_recipe_revision: Mapped[int | None] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ImportDispatchOutbox(Base):
    __tablename__ = "import_dispatch_outbox"
    __table_args__ = (
        CheckConstraint(
            "dispatch_count >= 0",
            name="ck_import_dispatch_outbox_count_nonnegative",
        ),
        Index(
            "ix_import_dispatch_outbox_pending",
            "available_at",
            postgresql_where=text("dispatched_at IS NULL"),
        ),
    )

    import_job_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("import_jobs.id", ondelete="CASCADE"),
        primary_key=True,
    )
    available_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    dispatched_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )
    dispatch_count: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default="0"
    )
    last_error: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class ImportDeadLetter(Base):
    __tablename__ = "import_dead_letters"
    __table_args__ = (
        CheckConstraint(
            "attempts > 0",
            name="ck_import_dead_letters_attempts_positive",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    import_job_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("import_jobs.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
    )
    failure_code: Mapped[str] = mapped_column(String(128), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class ImportQuotaEvent(Base):
    __tablename__ = "import_quota_events"
    __table_args__ = (
        UniqueConstraint(
            "user_id",
            "event_key",
            name="uq_import_quota_events_user_event",
        ),
        CheckConstraint(
            "operation IN ('submit', 'retry')",
            name="ck_import_quota_events_operation",
        ),
        Index(
            "ix_import_quota_events_user_occurred",
            "user_id",
            "occurred_at",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False
    )
    # SET NULL, not CASCADE: the monthly quota window (a calendar month, up
    # to 31 days) can outlast the 30-day retention of the job itself, so the
    # spend record must survive the job. The retention sweep prunes events
    # once their month can no longer be counted.
    import_job_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("import_jobs.id", ondelete="SET NULL"), nullable=True
    )
    operation: Mapped[str] = mapped_column(String(16), nullable=False)
    event_key: Mapped[str] = mapped_column(String(255), nullable=False)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )


class RecipeSlotReservation(Base):
    __tablename__ = "recipe_slot_reservations"
    __table_args__ = (
        CheckConstraint(
            "state IN ('reserved', 'consumed', 'released')",
            name="ck_recipe_slot_reservations_state",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True
    )
    import_job_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("import_jobs.id", ondelete="CASCADE"), unique=True
    )
    state: Mapped[str] = mapped_column(
        String(16), nullable=False, server_default="reserved"
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )


class ExtractionClaim(Base):
    __tablename__ = "extraction_claims"
    __table_args__ = (
        Index(
            "uq_extraction_claims_active_source_video",
            "source_video_id",
            unique=True,
            postgresql_where=text("released_at IS NULL"),
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    source_video_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("source_videos.id", ondelete="CASCADE"), nullable=False
    )
    owner_job_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("import_jobs.id", ondelete="CASCADE"), nullable=False
    )
    claim_version: Mapped[int] = mapped_column(
        Integer, nullable=False, server_default="1"
    )
    lease_expires_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    heartbeat_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    released_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class ProviderBudgetWindow(Base):
    __tablename__ = "provider_budget_windows"
    __table_args__ = (
        CheckConstraint(
            "window_ends_at > window_started_at",
            name="ck_provider_budget_windows_range",
        ),
        CheckConstraint(
            "maximum_units > 0",
            name="ck_provider_budget_windows_maximum_positive",
        ),
        CheckConstraint(
            "spent_units >= 0 AND reserved_units >= 0",
            name="ck_provider_budget_windows_units_nonnegative",
        ),
    )

    window_started_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), primary_key=True
    )
    window_ends_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )
    maximum_units: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    spent_units: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, server_default="0"
    )
    reserved_units: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, server_default="0"
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False
    )


class ProviderAttempt(Base):
    __tablename__ = "provider_attempts"
    __table_args__ = (
        UniqueConstraint(
            "import_job_id",
            "idempotency_key",
            name="uq_provider_attempts_job_idempotency",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    import_job_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("import_jobs.id", ondelete="CASCADE"), nullable=False
    )
    provider: Mapped[str] = mapped_column(String(64), nullable=False)
    operation: Mapped[str] = mapped_column(String(64), nullable=False)
    idempotency_key: Mapped[str] = mapped_column(String(255), nullable=False)
    external_job_id: Mapped[str | None] = mapped_column(String(255), nullable=True)
    status: Mapped[str] = mapped_column(String(32), nullable=False)
    latency_ms: Mapped[int | None] = mapped_column(Integer, nullable=True)
    billed_units: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    cost_usd: Mapped[Decimal | None] = mapped_column(Numeric(18, 8), nullable=True)
    reserved_units: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, server_default="0"
    )
    budget_window_started_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        ForeignKey("provider_budget_windows.window_started_at"),
        nullable=True,
    )
    reservation_expires_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True, index=True
    )
    failure_code: Mapped[str | None] = mapped_column(String(128), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    completed_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True), nullable=True
    )


class RecipeImage(Base):
    __tablename__ = "recipe_images"
    __table_args__ = (
        UniqueConstraint(
            "recipe_id", "order_index", name="uq_recipe_images_recipe_order"
        ),
        CheckConstraint(
            "(object_key IS NOT NULL) <> (remote_url IS NOT NULL)",
            name="ck_recipe_images_exactly_one_location",
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    object_key: Mapped[str | None] = mapped_column(Text, nullable=True)
    remote_url: Mapped[str | None] = mapped_column(Text, nullable=True)
    order_index: Mapped[int] = mapped_column(Integer, nullable=False)


class Ingredient(Base):
    __tablename__ = "ingredients"
    __table_args__ = (
        UniqueConstraint("recipe_id", "id", name="uq_ingredients_recipe_id"),
        UniqueConstraint(
            "recipe_id", "order_index", name="uq_ingredients_recipe_order"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    quantity_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    normalized_quantity: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 6), nullable=True
    )
    unit: Mapped[str | None] = mapped_column(String(64), nullable=True)
    name: Mapped[str] = mapped_column(Text, nullable=False)
    preparation: Mapped[str | None] = mapped_column(Text, nullable=True)
    order_index: Mapped[int] = mapped_column(Integer, nullable=False)


class RecipeStep(Base):
    __tablename__ = "recipe_steps"
    __table_args__ = (
        UniqueConstraint("recipe_id", "id", name="uq_recipe_steps_recipe_id"),
        UniqueConstraint(
            "recipe_id", "order_index", name="uq_recipe_steps_recipe_order"
        ),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    order_index: Mapped[int] = mapped_column(Integer, nullable=False)
    instruction: Mapped[str] = mapped_column(Text, nullable=False)
    source_start_seconds: Mapped[float | None] = mapped_column(Float, nullable=True)
    source_end_seconds: Mapped[float | None] = mapped_column(Float, nullable=True)


class StepIngredient(Base):
    __tablename__ = "step_ingredients"
    __table_args__ = (
        ForeignKeyConstraint(
            ["recipe_id", "step_id"],
            ["recipe_steps.recipe_id", "recipe_steps.id"],
            ondelete="CASCADE",
            name="fk_step_ingredients_step_same_recipe",
        ),
        ForeignKeyConstraint(
            ["recipe_id", "ingredient_id"],
            ["ingredients.recipe_id", "ingredients.id"],
            ondelete="CASCADE",
            name="fk_step_ingredients_ingredient_same_recipe",
        ),
    )

    recipe_id: Mapped[UUID] = mapped_column(Uuid, primary_key=True)
    step_id: Mapped[UUID] = mapped_column(Uuid, primary_key=True)
    ingredient_id: Mapped[UUID] = mapped_column(Uuid, primary_key=True)


class DetectedTimer(Base):
    __tablename__ = "detected_timers"
    __table_args__ = (Index("ix_detected_timers_recipe_step_id", "recipe_step_id"),)

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recipe_step_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipe_steps.id", ondelete="CASCADE"), nullable=False
    )
    label: Mapped[str] = mapped_column(Text, nullable=False)
    duration_seconds: Mapped[int] = mapped_column(Integer, nullable=False)


class Nutrition(Base):
    __tablename__ = "nutrition"

    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), primary_key=True
    )
    calories: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    protein_grams: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    carbohydrate_grams: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 6), nullable=True
    )
    fat_grams: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    saturated_fat_grams: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 6), nullable=True
    )
    fiber_grams: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    sugar_grams: Mapped[Decimal | None] = mapped_column(Numeric(18, 6), nullable=True)
    sodium_milligrams: Mapped[Decimal | None] = mapped_column(
        Numeric(18, 6), nullable=True
    )
    serving_basis: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    is_estimated: Mapped[bool] = mapped_column(Boolean, nullable=False)


class OtherNutrient(Base):
    __tablename__ = "other_nutrients"
    __table_args__ = (
        Index("ix_other_nutrients_nutrition_recipe_id", "nutrition_recipe_id"),
    )

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    nutrition_recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("nutrition.recipe_id", ondelete="CASCADE"), nullable=False
    )
    name: Mapped[str] = mapped_column(Text, nullable=False)
    amount: Mapped[Decimal] = mapped_column(Numeric(18, 6), nullable=False)
    unit: Mapped[str] = mapped_column(String(64), nullable=False)


class FieldUncertainty(Base):
    __tablename__ = "field_uncertainties"
    __table_args__ = (Index("ix_field_uncertainties_recipe_id", "recipe_id"),)

    id: Mapped[UUID] = mapped_column(Uuid, primary_key=True, default=uuid4)
    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    ingredient_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("ingredients.id", ondelete="CASCADE"), nullable=True
    )
    step_id: Mapped[UUID | None] = mapped_column(
        Uuid, ForeignKey("recipe_steps.id", ondelete="CASCADE"), nullable=True
    )
    field: Mapped[str] = mapped_column(Text, nullable=False)
    reason: Mapped[str] = mapped_column(Text, nullable=False)
    confidence: Mapped[Decimal | None] = mapped_column(Numeric(5, 4), nullable=True)


class UserSyncState(Base):
    __tablename__ = "user_sync_state"
    __table_args__ = (
        CheckConstraint(
            "next_sequence > 0", name="ck_user_sync_state_next_sequence_positive"
        ),
        CheckConstraint(
            "minimum_retained_sequence > 0",
            name="ck_user_sync_state_minimum_retained_sequence_positive",
        ),
        CheckConstraint(
            "minimum_retained_sequence <= next_sequence",
            name="ck_user_sync_state_retention_before_next",
        ),
    )

    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    next_sequence: Mapped[int] = mapped_column(
        BigInteger, nullable=False, server_default="1"
    )
    minimum_retained_sequence: Mapped[int] = mapped_column(
        BigInteger,
        nullable=False,
        server_default="1",
    )


class RecipeChange(Base):
    __tablename__ = "recipe_changes"
    __table_args__ = (
        CheckConstraint("kind IN ('upsert', 'delete')", name="ck_recipe_changes_kind"),
    )

    user_id: Mapped[UUID] = mapped_column(
        Uuid,
        ForeignKey("users.id", ondelete="CASCADE"),
        primary_key=True,
    )
    sequence: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    recipe_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("recipes.id", ondelete="CASCADE"), nullable=False
    )
    kind: Mapped[str] = mapped_column(String(16), nullable=False)
    recipe_revision: Mapped[int] = mapped_column(Integer, nullable=False)
    changed_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class DiscoverImpression(Base):
    """The last time a Discover page served one source to one cook.

    Overwritten rather than appended, so the table is bounded by corpus size
    per cook rather than by how often they scroll. The feed reads it to demote
    what was seen recently — never to exclude — and the retention sweep
    deletes aged rows, which together are the decay rule: nothing is
    suppressed forever and no cook can exhaust the feed.
    """

    __tablename__ = "discover_impressions"
    __table_args__ = (
        # Serves the retention sweep's per-user cutoff scan. The feed's own
        # lookup is one cook's row for a specific source, which the primary
        # key already answers.
        Index("ix_discover_impressions_user_seen_at", "user_id", "seen_at"),
    )

    user_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("users.id", ondelete="CASCADE"), primary_key=True
    )
    source_video_id: Mapped[UUID] = mapped_column(
        Uuid, ForeignKey("source_videos.id", ondelete="CASCADE"), primary_key=True
    )
    seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)


class USDAFood(Base):
    """A FoodData Central detail response, stored exactly as it arrived.

    The payload is kept raw rather than parsed into columns so that changes to
    how a record is validated or ranked apply to everything already collected.
    The branded panels that used to cost recipes their nutrition are still in
    here; they are simply rejected at read time now.
    """

    __tablename__ = "usda_foods"

    fdc_id: Mapped[int] = mapped_column(Integer, primary_key=True)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    fetched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )


class USDASearch(Base):
    """A FoodData Central search response for one normalized query.

    Keyed by the same normalization the client applies before searching, so
    "  Chickpeas   CANNED " and "chickpeas canned" are one row.
    """

    __tablename__ = "usda_searches"

    query: Mapped[str] = mapped_column(String(255), primary_key=True)
    payload: Mapped[dict[str, Any]] = mapped_column(JSON, nullable=False)
    fetched_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
