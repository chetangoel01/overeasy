"""Give already-stored ingredients the quantity split the app renders from.

Rows are rendered from `normalized_quantity`, `unit` and `name`, and the
creator's phrase is a note nothing prints. Recipes imported before that was
true carry amounts that live only in the phrase — "2 cups" with no number
beside it — and would now read as a bare "orzo". Others have no amount at
all and need saying so, which is what `is_to_taste` is for.

Nothing is asked of a model here. `IngredientDTO` derives the split as it
reads a row, so this walks the library, compares what the reader derives
against what the row actually holds, and writes the difference back. It is
the same guarantee an import gets, applied to the recipes that predate it.

The write goes through the path a cook's own edit takes, so the revision
bumps and the change reaches the device's next sync page. A row updated in
place would never arrive.

    python -m ladle.admin.backfill_ingredient_quantities
    python -m ladle.admin.backfill_ingredient_quantities --apply

It prints the table and writes nothing unless `--apply` is given: the fix
for a bad parse is to correct it before it reaches 40 libraries, not after.
"""

import argparse
import logging
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import timedelta
from decimal import Decimal
from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.contracts.recipes import IngredientDTO
from ladle.db.models import Ingredient, Recipe
from ladle.db.session import build_engine, build_session_factory
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService, SyncConflict
from ladle.worker.runtime import runtime_object_storage

LOGGER = logging.getLogger(__name__)


@dataclass
class BackfillRow:
    """One ingredient the run would change, printed identically dry or wet."""

    recipe_id: UUID
    title: str
    name: str
    quantity_text: str | None
    before: str
    after: str
    action: str


class IngredientQuantityBackfillService:
    def __init__(
        self,
        *,
        recipes: RecipeService,
        repository: RecipeRepository,
    ) -> None:
        self._recipes = recipes
        self._repository = repository

    def run(
        self,
        database: Session,
        *,
        limit: int | None,
        apply: bool,
    ) -> list[BackfillRow]:
        query = (
            select(Recipe)
            .where(Recipe.deleted_at.is_(None))
            .order_by(Recipe.created_at, Recipe.id)
        )
        if limit is not None:
            query = query.limit(limit)
        rows: list[BackfillRow] = []
        for stored in database.scalars(query).all():
            rows.extend(self._one(database, stored, apply=apply))
        return rows

    def _one(
        self,
        database: Session,
        stored: Recipe,
        *,
        apply: bool,
    ) -> list[BackfillRow]:
        # Reading is what derives the split: the DTO enforces it on the way
        # out, so the difference between the DTO and the row is exactly the
        # work this script exists to do.
        recipe = self._repository.to_dto(database, stored)
        current = {
            row.id: row
            for row in database.scalars(
                select(Ingredient).where(Ingredient.recipe_id == stored.id)
            )
        }
        changes = [
            _describe(stored, value, current[value.id])
            for value in recipe.ingredients
            if value.id in current and _differs(value, current[value.id])
        ]
        if not changes:
            return []
        if not apply:
            return changes
        try:
            self._recipes.upsert(
                database,
                user_id=stored.user_id,
                recipe=recipe,
                base_revision=stored.revision,
            )
        except SyncConflict:
            return [
                BackfillRow(
                    recipe_id=change.recipe_id,
                    title=change.title,
                    name=change.name,
                    quantity_text=change.quantity_text,
                    before=change.before,
                    after=change.after,
                    action="skipped: edited during the run",
                )
                for change in changes
            ]
        return changes


def _differs(value: IngredientDTO, row: Ingredient) -> bool:
    return (
        value.normalized_quantity != row.normalized_quantity
        or (value.unit or None) != (row.unit or None)
        or value.is_to_taste != row.is_to_taste
    )


def _describe(stored: Recipe, value: IngredientDTO, row: Ingredient) -> BackfillRow:
    if value.is_to_taste and not row.is_to_taste:
        action = "no quantity to render"
    elif row.normalized_quantity is None and value.normalized_quantity is not None:
        action = "split from the phrase"
    else:
        action = "unit from the phrase"
    return BackfillRow(
        recipe_id=stored.id,
        title=stored.title,
        name=value.name,
        quantity_text=row.quantity_text,
        before=_amount(row.normalized_quantity, row.unit, row.is_to_taste),
        after=_amount(value.normalized_quantity, value.unit, value.is_to_taste),
        action=action,
    )


def _amount(quantity: Decimal | None, unit: str | None, is_to_taste: bool) -> str:
    if is_to_taste:
        return "no quantity"
    if quantity is None:
        return "—"
    text = f"{quantity.normalize():f}"
    return f"{text} {unit}" if unit else text


_COLUMNS = ("recipe", "ingredient", "phrase", "stored", "becomes", "action")


def render_table(rows: Sequence[BackfillRow]) -> str:
    if not rows:
        return "Every stored ingredient already carries its quantity."
    body = [
        (
            row.title[:30],
            row.name[:24],
            (row.quantity_text or "—")[:20],
            row.before[:16],
            row.after[:16],
            row.action,
        )
        for row in rows
    ]
    widths = [
        max(len(heading), *(len(line[index]) for line in body))
        for index, heading in enumerate(_COLUMNS)
    ]
    lines = [
        "  ".join(
            value.ljust(width) for value, width in zip(_COLUMNS, widths, strict=True)
        ).rstrip(),
        "  ".join("-" * width for width in widths),
    ]
    lines.extend(
        "  ".join(
            value.ljust(width) for value, width in zip(line, widths, strict=True)
        ).rstrip()
        for line in body
    )
    return "\n".join(lines)


def build_service(settings: Settings) -> IngredientQuantityBackfillService:
    """The repository the API itself would use.

    A recipe whose photo lives in object storage cannot be read back without
    something to sign the URL with, and every recipe has to be readable for
    the run to be a complete answer.
    """

    storage = runtime_object_storage()
    object_url: Callable[[str], str] | None = None
    if storage is not None:
        signing = storage

        def object_url(key: str) -> str:
            return signing.signed_read_url(key, expires_in=timedelta(hours=6))

    repository = RecipeRepository(object_url=object_url)
    return IngredientQuantityBackfillService(
        recipes=RecipeService(clock=SystemClock(), repository=repository),
        repository=repository,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Give stored ingredients the quantity split rows render from",
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="write the changes; without it the table is printed and nothing moves",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="stop after this many recipes",
    )
    arguments = parser.parse_args(argv)
    limit: int | None = arguments.limit
    apply: bool = arguments.apply
    if limit is not None and limit < 1:
        parser.error("--limit must be at least 1")

    settings = Settings()
    sessions = build_session_factory(build_engine(settings.database_url))
    service = build_service(settings)
    with sessions() as database:
        rows = service.run(database, limit=limit, apply=apply)
        if apply:
            database.commit()
        else:
            database.rollback()
    print(render_table(rows))
    recipes = len({row.recipe_id for row in rows})
    written = sum(1 for row in rows if not row.action.startswith("skipped"))
    print(
        f"\n{len(rows)} ingredients in {recipes} recipes, "
        f"{written} {'written' if apply else 'to write (dry run)'}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
