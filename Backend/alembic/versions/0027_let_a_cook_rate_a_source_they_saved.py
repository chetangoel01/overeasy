"""let a cook rate a source they saved

Discover could say how many cooks saved a recipe and how many people liked
the video, and neither says whether the dish was any good. This is where that
answer is kept: one row per (cook, source) holding a whole number of stars
from one to five.

The rating belongs to the shared source, not to the cook's own copy. Everyone
who saved the same video feeds one average, and whatever a cook changed in
their private copy stays private. The pair is the primary key, so changing a
rating is an update — two rows would let one cook count twice.

Only aggregates are ever served: a count, and an average once at least
`LADLE_RATING_MINIMUM_COUNT` cooks have rated (three by default). Nothing
reads this table to say who rated what.

Both foreign keys cascade. Deleting an account takes its ratings with it, and
a source removed from the corpus takes its rows with it too. No retention
sweep touches the table: a rating is something the cook wrote, like a recipe,
and lasts as long as the account does.

The `source_video_id` index serves the per-source average; the primary key
leads with the cook and already serves "what did I give this".

Revision ID: 0027
Revises: 0026
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0027"
down_revision: str | Sequence[str] | None = "0026"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "recipe_ratings",
        sa.Column(
            "user_id",
            sa.Uuid(),
            sa.ForeignKey("users.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column(
            "source_video_id",
            sa.Uuid(),
            sa.ForeignKey("source_videos.id", ondelete="CASCADE"),
            primary_key=True,
        ),
        sa.Column("stars", sa.SmallInteger(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint(
            "stars BETWEEN 1 AND 5",
            name="ck_recipe_ratings_stars_range",
        ),
    )
    op.create_index(
        "ix_recipe_ratings_source_video_id",
        "recipe_ratings",
        ["source_video_id"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_recipe_ratings_source_video_id",
        table_name="recipe_ratings",
    )
    op.drop_table("recipe_ratings")
