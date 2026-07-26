"""add durable App Attest challenges and keys

Revision ID: 0005
Revises: 0004
Create Date: 2026-07-26
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "app_attest_challenges",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("installation_id", sa.String(length=255), nullable=False),
        sa.Column("purpose", sa.String(length=32), nullable=False),
        sa.Column("challenge_hash", sa.LargeBinary(length=32), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("consumed_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "purpose IN ('guestCreation', 'importSubmission', 'importRetry')",
            name="ck_app_attest_challenges_purpose",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_app_attest_challenges_expires_at",
        "app_attest_challenges",
        ["expires_at"],
        unique=False,
    )
    op.create_table(
        "app_attest_keys",
        sa.Column("key_id", sa.String(length=255), nullable=False),
        sa.Column("installation_id", sa.String(length=255), nullable=False),
        sa.Column("device_id", sa.Uuid(), nullable=True),
        sa.Column("public_key", sa.LargeBinary(), nullable=False),
        sa.Column("receipt", sa.LargeBinary(), nullable=False),
        sa.Column("environment", sa.String(length=16), nullable=False),
        sa.Column(
            "assertion_counter",
            sa.BigInteger(),
            server_default="0",
            nullable=False,
        ),
        sa.Column(
            "status",
            sa.String(length=16),
            server_default="valid",
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.Column("last_asserted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("revocation_reason", sa.String(length=128), nullable=True),
        sa.CheckConstraint(
            "environment IN ('development', 'production')",
            name="ck_app_attest_keys_environment",
        ),
        sa.CheckConstraint(
            "status IN ('valid', 'revoked')",
            name="ck_app_attest_keys_status",
        ),
        sa.ForeignKeyConstraint(
            ["device_id"],
            ["devices.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("key_id"),
    )
    op.create_index(
        "ix_app_attest_keys_device_id",
        "app_attest_keys",
        ["device_id"],
        unique=False,
    )
    op.create_index(
        "ix_app_attest_keys_installation_id",
        "app_attest_keys",
        ["installation_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(
        "ix_app_attest_keys_installation_id",
        table_name="app_attest_keys",
    )
    op.drop_index("ix_app_attest_keys_device_id", table_name="app_attest_keys")
    op.drop_table("app_attest_keys")
    op.drop_index(
        "ix_app_attest_challenges_expires_at",
        table_name="app_attest_challenges",
    )
    op.drop_table("app_attest_challenges")
