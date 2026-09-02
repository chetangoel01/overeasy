"""keep the raw USDA responses so lookups stop leaving the database

Every import re-asked FoodData Central for the same handful of pantry staples,
which costs a round trip per ingredient, burns quota, and makes imports fail
whenever USDA is slow or down. The responses are reference data: they describe
foods, not users, so one copy serves every import.

Payloads are stored raw. Ranking and validation happen when a row is read, so
correcting either of those — as 1766375 did — applies to everything already
collected instead of only to what is fetched afterwards.

Revision ID: 0020
Revises: 0019
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0020"
down_revision: str | Sequence[str] | None = "0019"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "usda_foods",
        sa.Column("fdc_id", sa.Integer(), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.PrimaryKeyConstraint("fdc_id", name="pk_usda_foods"),
    )
    op.create_table(
        "usda_searches",
        sa.Column("query", sa.String(length=255), nullable=False),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column(
            "fetched_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.PrimaryKeyConstraint("query", name="pk_usda_searches"),
    )


def downgrade() -> None:
    op.drop_table("usda_searches")
    op.drop_table("usda_foods")
