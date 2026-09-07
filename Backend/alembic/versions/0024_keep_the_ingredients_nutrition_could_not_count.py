"""keep the ingredients nutrition could not count

One ingredient no food record answered used to cost a recipe its whole
nutrition panel. It no longer does: whatever matched is totalled and whatever
did not is skipped and named. What was skipped has to be stored.

`nutrition_skips` is one row per ingredient left out, per recipe. A row rather
than a JSON column on `nutrition`, because the recipe where nothing matched has
no `nutrition` row to hang a column off and is exactly the recipe worth looking
at, and because the operator question this feeds — which foods are missed most
often, and on whose recipes — is a `GROUP BY` over rows. It is rewritten whole
whenever a recipe's nutrition is, so it describes what is missing now rather
than everything that ever was.

These rows are also where the wire's `approximate` marker is read from, which
is why no column was added beside the totals for it: `PUT /recipes/{id}`
rewrites a recipe's nutrition from what the client sent, and a client that has
never heard of the field would clear it on the first title edit. Nothing a
client writes reaches this table.

Cascades on the recipe: deleting a recipe takes its skips with it. The name is
stored rather than a link to the ingredient row, because the panel counts foods
across recipes and the ingredient rows are replaced wholesale on every
re-import.

Revision ID: 0024
Revises: 0023
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0024"
down_revision: str | Sequence[str] | None = "0023"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "nutrition_skips",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column(
            "recipe_id",
            sa.Uuid(),
            sa.ForeignKey("recipes.id", ondelete="CASCADE"),
            nullable=False,
        ),
        sa.Column("ingredient_name", sa.Text(), nullable=False),
        sa.Column("code", sa.String(64), nullable=False),
        sa.Column("estimated_grams", sa.Numeric(18, 6), nullable=True),
        sa.Column(
            "recorded_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
    )
    op.create_index(
        "ix_nutrition_skips_recipe_id",
        "nutrition_skips",
        ["recipe_id"],
    )
    op.create_index(
        "ix_nutrition_skips_ingredient_name",
        "nutrition_skips",
        ["ingredient_name"],
    )


def downgrade() -> None:
    op.drop_index("ix_nutrition_skips_ingredient_name", table_name="nutrition_skips")
    op.drop_index("ix_nutrition_skips_recipe_id", table_name="nutrition_skips")
    op.drop_table("nutrition_skips")
