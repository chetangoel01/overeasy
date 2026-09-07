"""tag recipes by diet, cuisine and keyword

A cook who is vegetarian has to scroll past every chicken video in the Watch
feed to find the one recipe they can eat, because nothing stored about a
recipe says what it is. These two tables are what a filter can ask.

`recipe_tags` holds the three closed vocabularies — diet, cuisine, keyword —
in one table, because the query is identical for each and the primary key is
the question the filter asks: does this recipe carry this value in this
family. There is nothing else to store; a tag has no order and no confidence.

`recipe_keyword_proposals` holds terms the extraction model invented. They are
kept in their own table rather than as a fourth family so that "a proposal is
not filterable until somebody promotes it" is a property of the schema and not
a rule in the query: the Discover filter reads `recipe_tags` and cannot reach
these rows. Promoting one means adding it to `RecipeKeyword` in
`ladle/contracts/tags.py` and re-running the tag backfill.

Both cascade from the recipe, which is what already deletes a recipe's
ingredients and steps, so account deletion and the retention sweep need no
changes.

Nothing is backfilled here. `ladle.admin.backfill_tags` re-runs extraction
over the stored corpus, and until it has, every recipe simply carries no tags
— which is why a filter must never be the thing that hides an untagged recipe
from its owner.

Revision ID: 0025
Revises: 0024
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0025"
down_revision: str | Sequence[str] | None = "0024"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "recipe_tags",
        sa.Column("recipe_id", sa.Uuid(), nullable=False),
        sa.Column("family", sa.String(length=16), nullable=False),
        sa.Column("value", sa.String(length=64), nullable=False),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("recipe_id", "family", "value"),
        sa.CheckConstraint(
            "family IN ('diet', 'cuisine', 'keyword')",
            name="ck_recipe_tags_family",
        ),
    )
    op.create_index(
        "ix_recipe_tags_family_value",
        "recipe_tags",
        ["family", "value"],
    )
    op.create_table(
        "recipe_keyword_proposals",
        sa.Column("recipe_id", sa.Uuid(), nullable=False),
        sa.Column("value", sa.String(length=64), nullable=False),
        sa.ForeignKeyConstraint(["recipe_id"], ["recipes.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("recipe_id", "value"),
    )


def downgrade() -> None:
    op.drop_table("recipe_keyword_proposals")
    op.drop_index("ix_recipe_tags_family_value", table_name="recipe_tags")
    op.drop_table("recipe_tags")
