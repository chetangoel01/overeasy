"""record provider-reported cost in US dollars

Revision ID: 0013
Revises: 0012
Create Date: 2026-08-24
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "provider_attempts",
        sa.Column("cost_usd", sa.Numeric(precision=18, scale=8), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("provider_attempts", "cost_usd")
