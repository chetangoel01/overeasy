"""enforce one provider identity per user

A user could claim additional Apple or Google identities while already
owning one, and account deletion only revokes the single identity row it
looks up. Duplicates left by that bug are collapsed to the oldest row per
user (ties broken by subject) before the unique constraint is created; the
dropped rows' grants cannot be revoked from a migration, but the kept
identity still revokes normally when the account is deleted.

Revision ID: 0015
Revises: 0014
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0015"
down_revision: str | Sequence[str] | None = "0014"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute(
        """
        DELETE FROM apple_identities AS extra
        USING apple_identities AS kept
        WHERE extra.user_id = kept.user_id
          AND (kept.created_at, kept.apple_sub)
            < (extra.created_at, extra.apple_sub)
        """
    )
    op.execute(
        """
        DELETE FROM google_identities AS extra
        USING google_identities AS kept
        WHERE extra.user_id = kept.user_id
          AND (kept.created_at, kept.google_sub)
            < (extra.created_at, extra.google_sub)
        """
    )
    op.create_unique_constraint(
        "uq_apple_identities_user_id",
        "apple_identities",
        ["user_id"],
    )
    op.create_unique_constraint(
        "uq_google_identities_user_id",
        "google_identities",
        ["user_id"],
    )


def downgrade() -> None:
    op.drop_constraint(
        "uq_apple_identities_user_id",
        "apple_identities",
        type_="unique",
    )
    op.drop_constraint(
        "uq_google_identities_user_id",
        "google_identities",
        type_="unique",
    )
