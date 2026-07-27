"""allow a validated remote thumbnail when object storage is unavailable

Revision ID: 0012
Revises: 0011
Create Date: 2026-07-27
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0012"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "extraction_cache",
        sa.Column("thumbnail_remote_url", sa.Text(), nullable=True),
    )
    op.create_check_constraint(
        "ck_extraction_cache_one_thumbnail_location",
        "extraction_cache",
        (
            "thumbnail_object_key IS NULL "
            "OR thumbnail_remote_url IS NULL"
        ),
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_extraction_cache_one_thumbnail_location",
        "extraction_cache",
        type_="check",
    )
    op.drop_column("extraction_cache", "thumbnail_remote_url")
