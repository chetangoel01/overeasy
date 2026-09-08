"""say when an ingredient has no quantity

An ingredient is a quantity, a unit and a name, and the app renders a row
from exactly those. That leaves one honest exception: "salt to taste", or a
caption that named a food and no amount at all. Extraction has always known
the difference — `ExtractedIngredient.is_to_taste` — and threw the answer
away at the door, because the recipe tables had nowhere to put it.

Without the column the client cannot tell "no amount was ever given" from
"the amount was lost", and has to guess from an empty quantity; the guess is
what printed the creator's phrase beside the split and said the unit twice.

`false` is the right default for every stored row: an ingredient that does
have an amount keeps it, and the ones that do not are found by reading their
`quantity_text`, which is what `ladle.admin.backfill_ingredient_quantities`
does. Nothing is derived here — a migration that parsed prose would be doing
the backfill's job inside a transaction nobody can review.

Revision ID: 0026
Revises: 0025
"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = "0026"
down_revision: str | Sequence[str] | None = "0025"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "ingredients",
        sa.Column(
            "is_to_taste",
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )


def downgrade() -> None:
    op.drop_column("ingredients", "is_to_taste")
