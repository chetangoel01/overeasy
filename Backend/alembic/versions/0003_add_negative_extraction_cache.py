"""add_negative_extraction_cache

Revision ID: 0003
Revises: 0002
Create Date: 2026-07-23 23:45:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0003"
down_revision: str | Sequence[str] | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "negative_extraction_cache",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("source_video_id", sa.Uuid(), nullable=False),
        sa.Column("reason", sa.String(length=32), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "reason IN ('privateOrDeleted', 'parserUnavailable')",
            name="ck_negative_extraction_cache_reason",
        ),
        sa.ForeignKeyConstraint(
            ["source_video_id"],
            ["source_videos.id"],
            name=op.f("fk_negative_extraction_cache_source_video_id_source_videos"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint(
            "id",
            name=op.f("pk_negative_extraction_cache"),
        ),
        sa.UniqueConstraint(
            "source_video_id",
            name=op.f("uq_negative_extraction_cache_source_video_id"),
        ),
    )


def downgrade() -> None:
    op.drop_table("negative_extraction_cache")
