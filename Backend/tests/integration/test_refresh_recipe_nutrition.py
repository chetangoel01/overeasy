"""The nutrition refresh replaces a recipe's nutrition rows in place.

`scripts/refresh_recipe_nutrition.py` is the production one-off that recomputes
nutrition for recipes that already exist. Its replacement step runs against a
recipe the same session has just read, which is where a September 18 run
failed with a duplicate `pk_nutrition` on the first recipe of an account.
"""

import importlib.util
import json
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from alembic import command
from ladle.contracts.recipes import RecipeDTO
from ladle.db.models import Nutrition, OtherNutrient, Recipe, User, UserSyncState
from ladle.db.session import build_engine
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService
from ladle.recipes.template_clone import RecipeTemplate
from tests.conftest import alembic_config

ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT.parent / "Contracts" / "Fixtures" / "recipe-ready.json"


def load_script():
    path = ROOT / "scripts" / "refresh_recipe_nutrition.py"
    spec = importlib.util.spec_from_file_location("refresh_recipe_nutrition", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FrozenClock:
    def __init__(self, now: datetime) -> None:
        self._now = now

    def now(self) -> datetime:
        return self._now


def manual_recipe(recipe_id: UUID) -> RecipeDTO:
    value = json.loads(FIXTURE.read_text())
    value.update(
        {
            "id": str(recipe_id),
            "source": "other",
            "originalURL": f"https://manual.ladle.local/{recipe_id}",
            "revision": 1,
        }
    )
    return RecipeDTO.model_validate(value)


def seed(engine, recipe_id: UUID) -> UUID:
    user_id = uuid4()
    now = datetime(2026, 9, 18, 6, 0, tzinfo=UTC)
    with Session(engine) as database, database.begin():
        database.add(User(id=user_id, kind="guest", created_at=now))
        database.flush()
        database.add(UserSyncState(user_id=user_id, next_sequence=1))
        RecipeService(clock=FrozenClock(now)).upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id),
            base_revision=0,
        )
    return user_id


@pytest.mark.integration
def test_replacing_nutrition_on_a_recipe_the_session_has_read(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed(engine, recipe_id)
    script = load_script()
    repository = RecipeRepository(object_url=lambda key: f"https://signed.test/{key}")

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        # Exactly what the script does before it replaces: read the recipe
        # (which loads its nutrition rows into the session) and re-template it.
        dto = repository.to_dto(database, stored)
        template = RecipeTemplate.from_recipe(dto)
        assert template.nutrition is not None
        template = template.model_copy(
            update={
                "nutrition": template.nutrition.model_copy(
                    update={"calories": template.nutrition.calories + 10}
                )
            }
        )

        script._replace_nutrition(database, stored.id, template)
        script._announce(database, stored)
        database.commit()

    with Session(engine) as database:
        rows = database.scalars(
            select(Nutrition).where(Nutrition.recipe_id == recipe_id)
        ).all()
        assert len(rows) == 1
        assert rows[0].calories == template.nutrition.calories
        others = database.scalars(
            select(OtherNutrient).where(OtherNutrient.nutrition_recipe_id == recipe_id)
        ).all()
        assert len(others) == len(template.nutrition.other_nutrients)
        refreshed = database.get(Recipe, recipe_id)
        assert refreshed is not None and refreshed.revision == 2
