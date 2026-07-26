"""add transactional import dispatch and dead-letter state

Revision ID: 0009
Revises: 0008
Create Date: 2026-07-26
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "import_dispatch_outbox",
        sa.Column("import_job_id", sa.Uuid(), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("dispatched_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("dispatch_count", sa.Integer(), server_default="0", nullable=False),
        sa.Column("last_error", sa.String(length=128), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.CheckConstraint(
            "dispatch_count >= 0",
            name="ck_import_dispatch_outbox_count_nonnegative",
        ),
        sa.ForeignKeyConstraint(
            ["import_job_id"],
            ["import_jobs.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("import_job_id"),
    )
    op.create_index(
        "ix_import_dispatch_outbox_pending",
        "import_dispatch_outbox",
        ["available_at"],
        unique=False,
        postgresql_where=sa.text("dispatched_at IS NULL"),
    )
    op.create_table(
        "import_dead_letters",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("import_job_id", sa.Uuid(), nullable=False),
        sa.Column("failure_code", sa.String(length=128), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.CheckConstraint(
            "attempts > 0",
            name="ck_import_dead_letters_attempts_positive",
        ),
        sa.ForeignKeyConstraint(
            ["import_job_id"],
            ["import_jobs.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("import_job_id"),
    )


def downgrade() -> None:
    op.drop_table("import_dead_letters")
    op.drop_index(
        "ix_import_dispatch_outbox_pending",
        table_name="import_dispatch_outbox",
        postgresql_where=sa.text("dispatched_at IS NULL"),
    )
    op.drop_table("import_dispatch_outbox")
