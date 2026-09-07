"""The ops dashboard's backlog of foods nutrition keeps missing.

`nutrition_skips` records one row per ingredient a recipe could not count.
This is the read over those rows: which names come up most, which rung gave
up on them, and whose recipes they came from. The panel is the queue the
curated table is grown from, so the names travel exactly as recorded.
"""

from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from typing import Any
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import Engine
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.config import Settings
from ladle.db.models import NutritionSkip as NutritionSkipRow
from ladle.db.session import build_engine
from ladle.recipes.service import RecipeService
from tests.integration.recipes.test_recipe_service import manual_recipe, seed_user
from tests.integration.test_migrations import alembic_config

TOKEN = "ops-dashboard-secret-that-is-long-enough"
NOW = datetime(2026, 9, 7, 12, 0, tzinfo=UTC)


class FrozenClock:
    def __init__(self, value: datetime) -> None:
        self.value = value

    def now(self) -> datetime:
        return self.value


def _skip(
    recipe_id: UUID,
    name: str,
    *,
    code: str = "foodNotFound",
    grams: str | None = "6",
    at: datetime = NOW,
) -> NutritionSkipRow:
    return NutritionSkipRow(
        id=uuid4(),
        recipe_id=recipe_id,
        ingredient_name=name,
        code=code,
        estimated_grams=None if grams is None else Decimal(grams),
        recorded_at=at,
    )


def _seed(engine: Engine) -> None:
    """Six recipes, one cook, and a spread of misses across them.

    `garam masala` is the most-missed name and appears on more recipes than
    the panel will list, so the truncation is exercised. `curry leaves` has
    two different failure codes. `tamarind` is on a recipe the cook deleted,
    which must not go on voting for a food nobody has any more.
    """

    service = RecipeService(clock=FrozenClock(NOW))
    titles = ["Chicken Curry", "Dal Tadka", "Biryani", "Rasam", "Sambar", "Kootu"]
    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        recipes: list[UUID] = []
        for title in titles:
            recipe_id = uuid4()
            service.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(recipe_id, title=title),
                base_revision=0,
            )
            recipes.append(recipe_id)

        # Recorded oldest first, so the panel's "most recent" sample is the
        # tail of this list rather than the head.
        for offset, recipe_id in enumerate(recipes[:5]):
            database.add(
                _skip(
                    recipe_id,
                    "garam masala",
                    grams="6",
                    at=NOW + timedelta(minutes=offset),
                )
            )
        database.add(_skip(recipes[0], "curry leaves", grams="2"))
        database.add(
            _skip(recipes[1], "curry leaves", code="ambiguousFoodMatch", grams=None)
        )
        database.add(_skip(recipes[5], "  Ginger-Garlic Paste ", grams="15"))
        database.add(_skip(recipes[5], "tamarind", grams="30"))

        service.delete(
            database,
            user_id=user_id,
            recipe_id=recipes[5],
            base_revision=1,
        )


def _signed_in(engine: Engine) -> Iterator[TestClient]:
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        settings=Settings(ops_dashboard_token=TOKEN, _env_file=None),
    )
    with TestClient(app) as client:
        client.get("/ops", params={"token": TOKEN})
        yield client


@pytest.mark.integration
def test_the_panel_ranks_the_names_nutrition_keeps_missing(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    _seed(engine)

    for client in _signed_in(engine):
        payload: dict[str, Any] = client.get("/ops/nutrition-misses.json").json()

    assert payload["generatedAt"]
    # `tamarind` and the ginger-garlic paste were only on the deleted recipe.
    # API deletion is soft, so without the join they would still be counted.
    assert payload["totals"] == {"names": 2, "skips": 7, "recipes": 5}
    assert [name["name"] for name in payload["names"]] == [
        "garam masala",
        "curry leaves",
    ]

    masala, leaves = payload["names"]
    assert masala["skips"] == 5
    assert masala["recipes"] == 5
    assert masala["estimatedGrams"] == 30.0
    assert masala["codes"] == [{"code": "foodNotFound", "skips": 5}]

    # Bounded: five recipes carry the miss, three are listed, and the count
    # beside them is what tells the operator the rest exist.
    assert [recipe["title"] for recipe in masala["examples"]] == [
        "Sambar",
        "Rasam",
        "Biryani",
    ]
    assert all(UUID(recipe["id"]) for recipe in masala["examples"])

    # Two rungs gave up on the same name, most common first.
    assert leaves["codes"] == [
        {"code": "ambiguousFoodMatch", "skips": 1},
        {"code": "foodNotFound", "skips": 1},
    ]
    # One of the two rows recorded no mass; the other still says how heavy
    # the miss was.
    assert leaves["estimatedGrams"] == 2.0
    assert payload["limits"] == {"names": 25, "examples": 3}

    engine.dispose()


@pytest.mark.integration
def test_the_names_are_the_backlog_so_they_are_not_prettified(
    clean_postgres_url: str,
) -> None:
    """A sibling PR seeds the curated table from these strings.

    Trimming or title-casing them here would make the panel and the table
    disagree about what the pipeline actually asked for.
    """

    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service = RecipeService(clock=FrozenClock(NOW))
    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        recipe_id = uuid4()
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id, title="Kootu"),
            base_revision=0,
        )
        database.add(_skip(recipe_id, "  Ginger-Garlic Paste ", grams=None))

    for client in _signed_in(engine):
        payload = client.get("/ops/nutrition-misses.json").json()

    assert [name["name"] for name in payload["names"]] == ["  Ginger-Garlic Paste "]
    assert payload["names"][0]["estimatedGrams"] is None

    engine.dispose()


@pytest.mark.integration
def test_an_empty_table_is_a_panel_with_nothing_in_it_not_an_error(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)

    for client in _signed_in(engine):
        response = client.get("/ops/nutrition-misses.json")

    assert response.status_code == 200
    assert response.json()["names"] == []
    assert response.json()["totals"] == {"names": 0, "skips": 0, "recipes": 0}

    engine.dispose()
