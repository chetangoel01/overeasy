"""record the source platform's engagement counts on the video

Discover could only rank by saves inside Overeasy, because nothing about the
video's own popularity was kept. yt-dlp already returns like, view, comment
and repost counts plus the publish timestamp on every acquisition — the
extractor read only uploader and duration and dropped the rest.

These are typed nullable columns rather than keys inside the existing
`source_metadata` JSON because Discover ranks on them: a JSON expression
cannot use a plain index, and NULL has to sort last. `source_metadata` keeps
its current meaning and stays empty.

`counts_refreshed_at` records when the snapshot was taken. The counts drift
from the moment they are written, so the timestamp is what lets a re-import
decide whether refreshing is worth a provider call, and is the only honest
basis for telling a reader how old a number is.

Existing rows stay NULL: nothing is backfilled, so counts accrue from the
next import onward and the ranking falls back to save count until then.

Revision ID: 0019
Revises: 0018
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0019"
down_revision: str | Sequence[str] | None = "0018"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_COUNTS = ("like_count", "view_count", "comment_count", "repost_count")


def upgrade() -> None:
    for column in _COUNTS:
        op.add_column(
            "source_videos",
            sa.Column(column, sa.BigInteger(), nullable=True),
        )
    op.add_column(
        "source_videos",
        sa.Column("published_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.add_column(
        "source_videos",
        sa.Column("counts_refreshed_at", sa.DateTime(timezone=True), nullable=True),
    )
    # Partial: rows without counts never win a "most liked" page, so they do
    # not belong in the index that serves it.
    op.create_index(
        "ix_source_videos_like_count",
        "source_videos",
        [sa.text("like_count DESC")],
        postgresql_where="like_count IS NOT NULL",
    )


def downgrade() -> None:
    op.drop_index("ix_source_videos_like_count", table_name="source_videos")
    for column in ("counts_refreshed_at", "published_at", *_COUNTS):
        op.drop_column("source_videos", column)
