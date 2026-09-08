"""The one-off command that fixes the ingredients already in the library.

Rows render from the split now, so a recipe imported when the amount lived
only in the creator's phrase would read as a bare name. Nothing is asked of
a model here: reading a recipe derives the split, and the run writes back
the difference between what the reader derives and what the row holds.
"""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import select
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from alembic import command
from ladle.admin.backfill_ingredient_quantities import (
    IngredientQuantityBackfillService,
    render_table,
)
from ladle.contracts.recipes import RecipeDTO
from ladle.db.models import Ingredient, Recipe, RecipeChange, User, UserSyncState
from ladle.db.session import build_engine
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[4] / "Contracts" / "Fixtures" / "recipe-ready.json"
NOW = datetime(2026, 9, 8, 9, 0, tzinfo=UTC)


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def recipe_with_unique_ids(recipe_id: UUID) -> RecipeDTO:
    value = json.loads(FIXTURE.read_text())
    child_ids: dict[str, str] = {}
    for image in value["images"]:
        child_ids[image["id"]] = str(uuid5(recipe_id, image["id"]))
        image["id"] = child_ids[image["id"]]
    for ingredient in value["ingredients"]:
        original = ingredient["id"]
        child_ids[original] = str(uuid5(recipe_id, original))
        ingredient["id"] = child_ids[original]
    for step in value["steps"]:
        original = step["id"]
        child_ids[original] = str(uuid5(recipe_id, original))
        step["id"] = child_ids[original]
        step["ingredientIDs"] = [
            child_ids[ingredient_id] for ingredient_id in step["ingredientIDs"]
        ]
        for timer in step["timers"]:
            timer["id"] = str(uuid5(recipe_id, timer["id"]))
    for nutrient in value["nutrition"]["otherNutrients"]:
        nutrient["id"] = str(uuid5(recipe_id, nutrient["id"]))
    value.update(
        {
            "id": str(recipe_id),
            "source": "other",
            "originalURL": f"https://manual.ladle.local/{recipe_id}",
            "revision": 1,
        }
    )
    return RecipeDTO.model_validate(value)


def backfill() -> IngredientQuantityBackfillService:
    repository = RecipeRepository(object_url=lambda key: f"https://signed.test/{key}")
    return IngredientQuantityBackfillService(
        recipes=RecipeService(clock=FrozenClock(NOW), repository=repository),
        repository=repository,
    )


def seed_library(engine: Engine, recipe_id: UUID) -> None:
    """A recipe stored the way the corpus predating the guarantee holds it.

    The contract derives the split as it reads, so a legacy row cannot be
    written through the API at all; the rows are put back by hand, which is
    exactly the state 40 production recipes are in.
    """

    with Session(engine) as database, database.begin():
        user_id = uuid4()
        database.add(User(id=user_id, kind="guest", created_at=NOW))
        database.flush()
        database.add(UserSyncState(user_id=user_id, next_sequence=1))
        database.flush()
        RecipeService(clock=FrozenClock(NOW)).upsert(
            database,
            user_id=user_id,
            recipe=recipe_with_unique_ids(recipe_id),
            base_revision=0,
        )

    with Session(engine) as database, database.begin():
        rows = list(
            database.scalars(
                select(Ingredient)
                .where(Ingredient.recipe_id == recipe_id)
                .order_by(Ingredient.order_index)
            )
        )
        rows[0].quantity_text = "2 cups"
        rows[0].normalized_quantity = None
        rows[0].unit = None
        rows[1].name = "flaky salt"
        rows[1].quantity_text = None
        rows[1].normalized_quantity = None
        rows[1].unit = None


def stored_ingredients(engine: Engine, recipe_id: UUID) -> list[Ingredient]:
    with Session(engine) as database:
        return list(
            database.scalars(
                select(Ingredient)
                .where(Ingredient.recipe_id == recipe_id)
                .order_by(Ingredient.order_index)
            )
        )


@pytest.mark.integration
def test_a_dry_run_names_every_change_and_writes_none(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed_library(engine, recipe_id)

    with Session(engine) as database:
        rows = backfill().run(database, limit=None, apply=False)
        database.rollback()

    assert [row.action for row in rows] == [
        "split from the phrase",
        "no quantity to render",
    ]
    assert rows[0].before == "—"
    assert rows[0].after == "2 cups"
    assert rows[1].after == "no quantity"
    assert "flaky salt" in render_table(rows)

    unchanged = stored_ingredients(engine, recipe_id)
    assert unchanged[0].normalized_quantity is None
    assert unchanged[1].is_to_taste is False
    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.revision == 1

    engine.dispose()


@pytest.mark.integration
def test_applying_writes_the_split_through_the_path_an_edit_takes(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed_library(engine, recipe_id)

    with Session(engine) as database, database.begin():
        rows = backfill().run(database, limit=None, apply=True)

    assert len(rows) == 2
    written = stored_ingredients(engine, recipe_id)
    assert written[0].normalized_quantity == Decimal("2")
    assert written[0].unit == "cups"
    assert written[0].is_to_taste is False
    assert written[1].is_to_taste is True
    assert written[1].normalized_quantity is None

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        # The revision bumps, so the device's next sync page carries it.
        assert stored.revision == 2
        changes = list(
            database.scalars(select(RecipeChange).order_by(RecipeChange.sequence))
        )
        assert [change.kind for change in changes] == ["upsert", "upsert"]

    engine.dispose()


@pytest.mark.integration
def test_a_second_run_has_nothing_left_to_do(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed_library(engine, recipe_id)

    with Session(engine) as database, database.begin():
        backfill().run(database, limit=None, apply=True)

    with Session(engine) as database:
        rows = backfill().run(database, limit=None, apply=False)
        database.rollback()

    assert rows == []
    assert render_table(rows).startswith("Every stored ingredient")

    engine.dispose()
