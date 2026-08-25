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
    op.execute("DELETE FROM import_jobs WHERE status = 'cancelled'")
    op.drop_constraint("ck_import_jobs_status", "import_jobs", type_="check")
    op.create_check_constraint(
        "ck_import_jobs_status",
        "import_jobs",
        "status IN ('parsing', 'ready', 'needsReview', 'failed')",
    )
