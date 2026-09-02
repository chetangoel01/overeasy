"""record which Discover sources a cook has already been shown

Discover ranked the same corpus the same way on every open, so a cook who
opened Overeasy twice in a day saw the same rows twice. The ranking only turns
over when somebody saves something, which is not a schedule.

This is the per-user state that fixes it: one row per (cook, source) with the
moment that source was last served to them. The feed demotes what a cook has
seen recently rather than excluding it, so the table never has to be consulted
for a floor — once everything is seen the ranking simply returns to its plain
order, and nobody is ever handed a short page or an empty feed.

`seen_at` is overwritten rather than appended, so the table is bounded by
corpus size per cook, not by how often they scroll. The retention sweep deletes
rows older than `LADLE_RETENTION_DISCOVER_IMPRESSION_DAYS` (30 by default),
which is the decay rule: something seen an hour ago is suppressed, something
seen last month comes back.

Both foreign keys cascade. Deleting an account takes its impressions with it,
and a source removed from the corpus takes its rows with it too.

The `(user_id, seen_at)` index serves the retention sweep and any per-cook
read of the recent set; the primary key already serves the feed's join, which
looks up one cook's row for a specific source.

Revision ID: 0022
Revises: 0021
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0022"
down_revision: str | Sequence[str] | None = "0021"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "discover_impressions",
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
        sa.Column("seen_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index(
        "ix_discover_impressions_user_seen_at",
        "discover_impressions",
        ["user_id", "seen_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_discover_impressions_user_seen_at",
        table_name="discover_impressions",
    )
    op.drop_table("discover_impressions")
