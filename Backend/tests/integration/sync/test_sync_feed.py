from dataclasses import dataclass
from datetime import UTC, datetime
from uuid import uuid4

import pytest
from sqlalchemy.orm import Session

from alembic import command
from ladle.db.session import build_engine
from ladle.recipes.service import RecipeService
from ladle.sync.service import RecipeSyncService
from tests.integration.recipes.test_recipe_service import (
    manual_recipe,
    seed_user,
)
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.mark.integration
def test_cursor_pagination_has_no_gaps_or_duplicates(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipes = RecipeService(clock=FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC)))
    sync = RecipeSyncService()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        for index in range(3):
            recipes.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(uuid4(), title=f"Recipe {index}"),
                base_revision=0,
            )

    with Session(engine) as database:
        first = sync.page(database, user_id=user_id, cursor=0, limit=2)
        second = sync.page(
            database,
            user_id=user_id,
            cursor=first.next_cursor,
            limit=2,
        )
        replay = sync.page(database, user_id=user_id, cursor=0, limit=2)

    assert [change.sequence for change in first.changes] == [1, 2]
    assert first.has_more
    assert [change.sequence for change in second.changes] == [3]
    assert not second.has_more
    assert replay == first
    assert {change.recipe_id for change in first.changes}.isdisjoint(
        {change.recipe_id for change in second.changes}
    )

    engine.dispose()
