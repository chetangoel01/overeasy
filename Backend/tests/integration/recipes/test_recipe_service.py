import json
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from alembic import command
from ladle.contracts.recipes import RecipeDTO
from ladle.db.models import Recipe, RecipeChange, User, UserSyncState
from ladle.db.session import build_engine
from ladle.recipes.limits import GuestRecipeLimitReached
from ladle.recipes.service import (
    InvalidManualRecipe,
    RecipeService,
    SyncConflict,
)
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[4] / "Contracts" / "Fixtures" / "recipe-ready.json"


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def manual_recipe(recipe_id: UUID, *, title: str = "Lemon Orzo") -> RecipeDTO:
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
            "title": title,
            "source": "other",
            "originalURL": f"https://manual.ladle.local/{recipe_id}",
            "revision": 1,
        }
    )
    return RecipeDTO.model_validate(value)


def seed_user(database: Session, *, kind: str = "guest") -> UUID:
    user_id = uuid4()
    database.add(
        User(
            id=user_id,
            kind=kind,
            created_at=datetime(2026, 7, 23, 21, 0, tzinfo=UTC),
        )
    )
    database.flush()
    database.add(UserSyncState(user_id=user_id, next_sequence=1))
    database.flush()
    return user_id


@pytest.mark.integration
def test_manual_create_is_idempotent_and_persists_full_recipe_graph(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    service = RecipeService(clock=clock)
    recipe_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        created = service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id),
            base_revision=0,
        )
        repeated = service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id),
            base_revision=0,
        )

    assert created.revision == 1
    assert repeated == created
    assert created.ingredients[0].normalized_quantity == 2
    assert created.steps[0].ingredient_ids == [created.ingredients[0].id]
    assert created.nutrition is not None
    assert created.nutrition.calories == 540
    assert created.images[0].remote_url.host == "images.ladle.example"

    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(Recipe)) == 1
        assert database.scalar(select(func.count()).select_from(RecipeChange)) == 1

    engine.dispose()


@pytest.mark.integration
def test_matching_update_and_delete_emit_ordered_sync_changes(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    service = RecipeService(clock=clock)
    recipe_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id),
            base_revision=0,
        )

    clock.value = datetime(2026, 7, 23, 22, 0, tzinfo=UTC)
    with Session(engine) as database, database.begin():
        updated = service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id, title="Edited Orzo"),
            base_revision=1,
        )
    assert updated.revision == 2
    assert updated.title == "Edited Orzo"

    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(SyncConflict) as conflict,
    ):
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id, title="Stale"),
            base_revision=1,
        )
    assert conflict.value.current_recipe.title == "Edited Orzo"
    assert conflict.value.current_recipe.revision == 2

    with Session(engine) as database, database.begin():
        service.delete(
            database,
            user_id=user_id,
            recipe_id=recipe_id,
            base_revision=2,
        )

    with Session(engine) as database:
        changes = list(
            database.scalars(
                select(RecipeChange)
                .where(RecipeChange.user_id == user_id)
                .order_by(RecipeChange.sequence)
            )
        )
        assert [(change.sequence, change.kind) for change in changes] == [
            (1, "upsert"),
            (2, "upsert"),
            (3, "delete"),
        ]
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.deleted_at == clock.now()
        assert stored.revision == 3

    engine.dispose()


@pytest.mark.integration
def test_manual_source_and_guest_limit_are_enforced_under_user_lock(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service = RecipeService(clock=FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC)))

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        invalid = manual_recipe(uuid4()).model_copy(
            update={"original_url": "https://example.com/not-manual"}
        )
        with pytest.raises(InvalidManualRecipe):
            service.upsert(
                database,
                user_id=user_id,
                recipe=invalid,
                base_revision=0,
            )

    with Session(engine) as database, database.begin():
        for index in range(10):
            service.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(uuid4(), title=f"Recipe {index}"),
                base_revision=0,
            )

    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(GuestRecipeLimitReached),
    ):
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(uuid4(), title="Eleventh"),
            base_revision=0,
        )

    engine.dispose()
