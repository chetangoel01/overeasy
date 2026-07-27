"""add a per-user sync history retention floor

Revision ID: 0011
Revises: 0010
Create Date: 2026-07-26
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0011"
down_revision: str | None = "0010"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "user_sync_state",
        sa.Column(
            "minimum_retained_sequence",
            sa.BigInteger(),
            server_default="1",
            nullable=False,
        ),
    )
    op.create_check_constraint(
        "ck_user_sync_state_minimum_retained_sequence_positive",
        "user_sync_state",
        "minimum_retained_sequence > 0",
    )
    op.create_check_constraint(
        "ck_user_sync_state_retention_before_next",
        "user_sync_state",
        "minimum_retained_sequence <= next_sequence",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_user_sync_state_retention_before_next",
        "user_sync_state",
        type_="check",
    )
    op.drop_constraint(
        "ck_user_sync_state_minimum_retained_sequence_positive",
        "user_sync_state",
        type_="check",
    )
    op.drop_column("user_sync_state", "minimum_retained_sequence")
