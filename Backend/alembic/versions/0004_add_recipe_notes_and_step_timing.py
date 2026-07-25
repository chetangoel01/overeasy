"""add recipe notes and step source timing

Revision ID: 0004
Revises: 0003
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0004"
down_revision: str | Sequence[str] | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "recipes",
        sa.Column(
            "notes",
            sa.JSON(),
            nullable=False,
            server_default=sa.text("'[]'::json"),
        ),
    )
    op.add_column(
        "recipe_steps",
        sa.Column("source_start_seconds", sa.Float(), nullable=True),
    )
    op.add_column(
        "recipe_steps",
        sa.Column("source_end_seconds", sa.Float(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("recipe_steps", "source_end_seconds")
    op.drop_column("recipe_steps", "source_start_seconds")
    op.drop_column("recipes", "notes")
