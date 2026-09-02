"""store the display name and avatar a cook signs in with

The app already asked Apple for `.email` and `.fullName` and asked Google for a
profile, then dropped all of it on the floor: `users` held only an id, a kind
and a timestamp, so there was nothing to show a cook about themselves.

Apple is the reason this is urgent rather than tidy. It returns a full name
exactly once, on the first authorization for a given Apple ID and app, and
never again — not in the identity token, not on re-sign-in. Every sign-in that
happens before this column exists loses that name permanently.

Only the two fields the profile actually displays are stored. Email is
deliberately absent: the header shows an avatar, a name and an account kind,
and a column nothing renders is a privacy cost with no product behind it.

`display_name` is seeded once and never overwritten by a later sign-in, because
a cook can edit it and a re-sign-in must not undo that. `avatar_url` may
refresh, since it is the provider's own copy and has no local edit to lose.

Revision ID: 0021
Revises: 0020
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0021"
down_revision: str | Sequence[str] | None = "0020"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("display_name", sa.String(length=64), nullable=True),
    )
    op.add_column(
        "users",
        sa.Column("avatar_url", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "avatar_url")
    op.drop_column("users", "display_name")
