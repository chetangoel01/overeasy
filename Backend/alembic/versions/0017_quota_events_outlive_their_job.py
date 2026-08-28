"""let import quota events outlive their import job

The monthly import quota counts a calendar month of import_quota_events,
but the rows cascaded away with their job when the retention sweep
hard-deleted terminal jobs after 30 days — so in every 31-day month, quota
already spent could silently vanish and the user was granted a fresh slice
inside the same month. The events now survive job deletion (import_job_id
set to NULL) and the retention sweep prunes them once the month they were
counted in has passed.

Revision ID: 0017
Revises: 0016
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0017"
down_revision: str | Sequence[str] | None = "0016"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.drop_constraint(
        "fk_import_quota_events_import_job_id_import_jobs",
        "import_quota_events",
        type_="foreignkey",
    )
    op.alter_column(
        "import_quota_events",
        "import_job_id",
        existing_type=sa.Uuid(),
        nullable=True,
    )
    op.create_foreign_key(
        "fk_import_quota_events_import_job_id_import_jobs",
        "import_quota_events",
        "import_jobs",
        ["import_job_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint(
        "fk_import_quota_events_import_job_id_import_jobs",
        "import_quota_events",
        type_="foreignkey",
    )
    # Rows already detached from a deleted job cannot satisfy NOT NULL again.
    op.execute("DELETE FROM import_quota_events WHERE import_job_id IS NULL")
    op.alter_column(
        "import_quota_events",
        "import_job_id",
        existing_type=sa.Uuid(),
        nullable=False,
    )
    op.create_foreign_key(
        "fk_import_quota_events_import_job_id_import_jobs",
        "import_quota_events",
        "import_jobs",
        ["import_job_id"],
        ["id"],
        ondelete="CASCADE",
    )
