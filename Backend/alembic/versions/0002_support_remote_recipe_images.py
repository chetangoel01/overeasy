"""support_remote_recipe_images

Revision ID: 0002
Revises: 0001
Create Date: 2026-07-23 23:24:08.553436
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0002"
down_revision: str | Sequence[str] | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "recipe_images",
        sa.Column("remote_url", sa.Text(), nullable=True),
    )
    op.alter_column(
        "recipe_images",
        "object_key",
        existing_type=sa.TEXT(),
        nullable=True,
    )
    op.create_check_constraint(
        "ck_recipe_images_exactly_one_location",
        "recipe_images",
        "(object_key IS NOT NULL) <> (remote_url IS NOT NULL)",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_recipe_images_exactly_one_location",
        "recipe_images",
        type_="check",
    )
    op.execute(
        "UPDATE recipe_images SET object_key = remote_url WHERE object_key IS NULL"
    )
    op.alter_column(
        "recipe_images",
        "object_key",
        existing_type=sa.TEXT(),
        nullable=False,
    )
    op.drop_column("recipe_images", "remote_url")
