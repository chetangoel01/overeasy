"""add account deletion audit and object cleanup queue

Revision ID: 0010
Revises: 0009
Create Date: 2026-07-26
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0010"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "account_deletion_audits",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_digest", sa.LargeBinary(length=32), nullable=False),
        sa.Column("idempotency_digest", sa.LargeBinary(length=32), nullable=False),
        sa.Column("account_kind", sa.String(length=16), nullable=False),
        sa.Column("status", sa.String(length=32), nullable=False),
        sa.Column("failure_code", sa.String(length=128), nullable=True),
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
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "account_kind IN ('guest', 'apple', 'google')",
            name="ck_account_deletion_audits_kind",
        ),
        sa.CheckConstraint(
            "status IN ('requested', 'revokingProvider', 'deleting', "
            "'completed', 'failed')",
            name="ck_account_deletion_audits_status",
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("idempotency_digest"),
    )
    op.create_table(
        "object_deletion_queue",
        sa.Column("object_key", sa.Text(), nullable=False),
        sa.Column("reason", sa.String(length=64), nullable=False),
        sa.Column("available_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attempts", sa.Integer(), server_default="0", nullable=False),
        sa.Column("last_error", sa.String(length=128), nullable=True),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.CheckConstraint(
            "attempts >= 0",
            name="ck_object_deletion_queue_attempts_nonnegative",
        ),
        sa.PrimaryKeyConstraint("object_key"),
    )


def downgrade() -> None:
    op.drop_table("object_deletion_queue")
    op.drop_table("account_deletion_audits")
