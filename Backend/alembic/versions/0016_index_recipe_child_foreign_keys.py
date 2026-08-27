"""index the recipe child tables on their filtered foreign keys

Every recipe fetch filters detected_timers on recipe_step_id,
field_uncertainties on recipe_id and other_nutrients on
nutrition_recipe_id, and every recipe update deletes through the same
columns. None of them had an index — Postgres does not index a foreign
key's referencing column on its own, and unlike the other child tables
no leading-column unique constraint covers these — so each of those
statements was a sequential scan of a table that grows with every
user's recipes.

Revision ID: 0016
Revises: 0015
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0016"
down_revision: str | Sequence[str] | None = "0015"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "ix_detected_timers_recipe_step_id",
        "detected_timers",
        ["recipe_step_id"],
    )
    op.create_index(
        "ix_field_uncertainties_recipe_id",
        "field_uncertainties",
        ["recipe_id"],
    )
    op.create_index(
        "ix_other_nutrients_nutrition_recipe_id",
        "other_nutrients",
        ["nutrition_recipe_id"],
    )


def downgrade() -> None:
    op.drop_index("ix_other_nutrients_nutrition_recipe_id", "other_nutrients")
    op.drop_index("ix_field_uncertainties_recipe_id", "field_uncertainties")
    op.drop_index("ix_detected_timers_recipe_step_id", "detected_timers")
