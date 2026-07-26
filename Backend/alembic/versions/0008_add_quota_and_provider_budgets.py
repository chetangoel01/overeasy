"""add import quotas and atomic provider budget reservations

Revision ID: 0008
Revises: 0007
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0008"
down_revision: str | Sequence[str] | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "import_quota_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("import_job_id", sa.Uuid(), nullable=False),
        sa.Column("operation", sa.String(length=16), nullable=False),
        sa.Column("event_key", sa.String(length=255), nullable=False),
        sa.Column("occurred_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "operation IN ('submit', 'retry')",
            name="ck_import_quota_events_operation",
        ),
        sa.ForeignKeyConstraint(
            ["import_job_id"], ["import_jobs.id"], ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "user_id",
            "event_key",
            name="uq_import_quota_events_user_event",
        ),
    )
    op.create_index(
        "ix_import_quota_events_user_occurred",
        "import_quota_events",
        ["user_id", "occurred_at"],
        unique=False,
    )
    op.create_table(
        "provider_budget_windows",
        sa.Column(
            "window_started_at",
            sa.DateTime(timezone=True),
            nullable=False,
        ),
        sa.Column("window_ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("maximum_units", sa.Numeric(18, 6), nullable=False),
        sa.Column(
            "spent_units",
            sa.Numeric(18, 6),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "reserved_units",
            sa.Numeric(18, 6),
            server_default="0",
            nullable=False,
        ),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "maximum_units > 0",
            name="ck_provider_budget_windows_maximum_positive",
        ),
        sa.CheckConstraint(
            "window_ends_at > window_started_at",
            name="ck_provider_budget_windows_range",
        ),
        sa.CheckConstraint(
            "spent_units >= 0 AND reserved_units >= 0",
            name="ck_provider_budget_windows_units_nonnegative",
        ),
        sa.PrimaryKeyConstraint("window_started_at"),
    )
    op.add_column(
        "provider_attempts",
        sa.Column(
            "reserved_units",
            sa.Numeric(18, 6),
            server_default="0",
            nullable=False,
        ),
    )
    op.add_column(
        "provider_attempts",
        sa.Column(
            "budget_window_started_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
    )
    op.add_column(
        "provider_attempts",
        sa.Column(
            "reservation_expires_at",
            sa.DateTime(timezone=True),
            nullable=True,
        ),
    )
    op.create_foreign_key(
        "fk_provider_attempts_budget_window",
        "provider_attempts",
        "provider_budget_windows",
        ["budget_window_started_at"],
        ["window_started_at"],
    )
    op.create_index(
        "ix_provider_attempts_reservation_expires_at",
        "provider_attempts",
        ["reservation_expires_at"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_provider_attempts_reservation_expires_at",
        table_name="provider_attempts",
    )
    op.drop_constraint(
        "fk_provider_attempts_budget_window",
        "provider_attempts",
        type_="foreignkey",
    )
    op.drop_column("provider_attempts", "reservation_expires_at")
    op.drop_column("provider_attempts", "budget_window_started_at")
    op.drop_column("provider_attempts", "reserved_units")
    op.drop_table("provider_budget_windows")
    op.drop_index(
        "ix_import_quota_events_user_occurred",
        table_name="import_quota_events",
    )
    op.drop_table("import_quota_events")
