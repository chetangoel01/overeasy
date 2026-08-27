"""allow active imports to be cancelled

Revision ID: 0014
Revises: 0013
Create Date: 2026-08-25
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0014"
down_revision: str | None = "0013"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint("ck_import_jobs_status", "import_jobs", type_="check")
    op.create_check_constraint(
        "ck_import_jobs_status",
        "import_jobs",
        "status IN ('parsing', 'ready', 'needsReview', 'failed', 'cancelled')",
    )


def downgrade() -> None:
    # A cancelled job has no representation in the pre-0014 status set, but
    # deleting it would cascade away its quota, dispatch, dead-letter,
    # reservation and provider-attempt rows — silently refunding the user's
    # monthly import quota and destroying the billing trail. Remap instead.
    # 'failed' is the closest state the old set can express, and it needs a
    # reason because the wire contract rejects a failed job without one.
    op.execute(
        """
        UPDATE import_jobs
        SET status = 'failed',
            failure_reason = COALESCE(failure_reason, 'parserUnavailable'),
            stage = 'failed'
        WHERE status = 'cancelled'
        """
    )
    op.drop_constraint("ck_import_jobs_status", "import_jobs", type_="check")
    op.create_check_constraint(
        "ck_import_jobs_status",
        "import_jobs",
        "status IN ('parsing', 'ready', 'needsReview', 'failed')",
    )
