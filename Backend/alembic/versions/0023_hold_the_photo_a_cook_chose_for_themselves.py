"""hold the photo a cook chose for themselves

`users.avatar_url` is the provider's copy: a link to Google's servers, refreshed
on every sign-in because there was no local edit to lose. That is no longer
true. A cook can now pick their own picture, and the picture is ours — a JPEG
in the private bucket, keyed `avatars/<user id>/<uuid>.jpg`.

It needs its own column rather than reusing `avatar_url`, for two reasons. A
bucket key is not a URL: what the app is served is a signed read URL minted per
response and expiring in hours, so the stored value and the served value are
different things. And keeping them apart is what lets the provider's copy go on
refreshing without ever overriding the cook's: `avatar_url` still holds
whatever Google last said, `avatar_object_key` holds what the cook chose, and
the cook's wins in what is served.

Nullable, because most accounts have no chosen photo: an Apple cook with no
provider picture at all reads as null here and null in `avatar_url`, and a
Google cook who never picked one reads as null here alone.

Replacing or removing a photo queues the old object in `object_deletion_queue`
rather than deleting it inline, the way a replaced recipe image already does;
deleting the account queues it too.

Revision ID: 0023
Revises: 0022
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0023"
down_revision: str | Sequence[str] | None = "0022"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "users",
        sa.Column("avatar_object_key", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("users", "avatar_object_key")
