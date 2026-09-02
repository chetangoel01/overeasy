"""index the columns the Discover ranking groups and filters on

The Discover feed aggregates every public recipe row — group by
source_video_id, filtered on deleted_at, review_status, source and
source_cache_id — and until now none of those columns were indexed, so each
request planned a sequential scan and a hash aggregate over `recipes`. That
was invisible at a few hundred rows and stops being invisible as the corpus
grows, and it now runs once per page rather than once per feed.

`source_video_id` also backs the NOT IN sub-select of the caller's own saves
and the per-source lookups in the same request, so it earns a plain index of
its own beyond the composite.

No index is added for the new search filter: it is an unanchored ILIKE, which
a btree cannot serve. Making that indexable needs pg_trgm plus a GIN index,
and CREATE EXTENSION needs privileges this deployment may not have — so it is
left for when search actually gets slow, as a deliberate follow-up rather than
a migration that might fail on deploy.

Revision ID: 0018
Revises: 0017
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0018"
down_revision: str | Sequence[str] | None = "0017"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index(
        "ix_recipes_source_video_id",
        "recipes",
        ["source_video_id"],
    )
    op.create_index(
        "ix_recipes_discover_ranking",
        "recipes",
        ["review_status", "source", "source_video_id"],
        postgresql_where="deleted_at IS NULL AND source_cache_id IS NOT NULL",
    )


def downgrade() -> None:
    op.drop_index("ix_recipes_discover_ranking", table_name="recipes")
    op.drop_index("ix_recipes_source_video_id", table_name="recipes")
