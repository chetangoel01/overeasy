"""add Google identity

Revision ID: 0007
Revises: 0006
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0007"
down_revision: str | Sequence[str] | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint("ck_users_kind", "users", type_="check")
    op.create_check_constraint(
        "ck_users_kind",
        "users",
        "kind IN ('guest', 'apple', 'google')",
    )
    op.create_table(
        "google_identities",
        sa.Column("google_sub", sa.String(length=255), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("google_sub"),
    )


def downgrade() -> None:
    op.drop_table("google_identities")
    op.execute("UPDATE users SET kind = 'guest' WHERE kind = 'google'")
    op.drop_constraint("ck_users_kind", "users", type_="check")
    op.create_check_constraint(
        "ck_users_kind",
        "users",
        "kind IN ('guest', 'apple')",
    )
