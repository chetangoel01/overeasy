"""Tags through the store: written, read back, and never silently lost."""

from datetime import UTC, datetime
from uuid import uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from alembic import command
from ladle.contracts.tags import CuisineTag, DietTag, RecipeKeyword
from ladle.db.models import RecipeKeywordProposal, RecipeTag
from ladle.db.session import build_engine
from ladle.recipes.service import RecipeService
from tests.integration.recipes.test_recipe_service import (
    FrozenClock,
    manual_recipe,
    seed_user,
)
from tests.integration.test_migrations import alembic_config

TAGS = {
    "diets": [DietTag.VEGETARIAN, DietTag.GLUTEN_FREE],
    "cuisines": [CuisineTag.ITALIAN],
    "keywords": [RecipeKeyword.ONE_POT, RecipeKeyword.WEEKNIGHT],
    "keyword_proposals": ["picnic-food"],
}


@pytest.mark.integration
def test_tags_round_trip_and_proposals_stay_out_of_the_filterable_table(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service = RecipeService(clock=FrozenClock(datetime(2026, 9, 7, tzinfo=UTC)))
    recipe_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        created = service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id).model_copy(update=TAGS),
            base_revision=0,
        )

    assert created.diets == [DietTag.VEGETARIAN, DietTag.GLUTEN_FREE]
    assert created.cuisines == [CuisineTag.ITALIAN]
    assert created.keywords == [RecipeKeyword.ONE_POT, RecipeKeyword.WEEKNIGHT]
    assert created.keyword_proposals == ["picnic-food"]

    with Session(engine) as database:
        # The proposal is not a row the filter could ever reach: it lives in
        # a table the Discover query does not join.
        assert set(
            database.scalars(
                select(RecipeTag.value).where(RecipeTag.family == "keyword")
            )
        ) == {"onePot", "weeknight"}
        assert database.scalars(select(RecipeKeywordProposal.value)).all() == [
            "picnic-food"
        ]

    engine.dispose()


@pytest.mark.integration
def test_an_edit_that_omits_tags_keeps_them(clean_postgres_url: str) -> None:
    """The shipped app encodes no tag keys; its edits must not strip them."""

    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service = RecipeService(clock=FrozenClock(datetime(2026, 9, 7, tzinfo=UTC)))
    recipe_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id).model_copy(update=TAGS),
            base_revision=0,
        )

    with Session(engine) as database, database.begin():
        untagged = manual_recipe(recipe_id, title="Edited").model_copy(
            update={
                "diets": None,
                "cuisines": None,
                "keywords": None,
                "keyword_proposals": None,
            }
        )
        updated = service.upsert(
            database,
            user_id=user_id,
            recipe=untagged,
            base_revision=1,
        )

    assert updated.title == "Edited"
    assert updated.diets == [DietTag.VEGETARIAN, DietTag.GLUTEN_FREE]
    assert updated.keyword_proposals == ["picnic-food"]

    engine.dispose()


@pytest.mark.integration
def test_an_edit_that_sends_empty_lists_clears_them(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service = RecipeService(clock=FrozenClock(datetime(2026, 9, 7, tzinfo=UTC)))
    recipe_id = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id).model_copy(update=TAGS),
            base_revision=0,
        )

    with Session(engine) as database, database.begin():
        cleared = service.upsert(
            database,
            user_id=user_id,
            recipe=manual_recipe(recipe_id).model_copy(
                update={
                    "diets": [],
                    "cuisines": [],
                    "keywords": [],
                    "keyword_proposals": [],
                }
            ),
            base_revision=1,
        )

    assert cleared.diets == []
    assert cleared.keyword_proposals == []

    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(RecipeTag)) == 0
        assert (
            database.scalar(select(func.count()).select_from(RecipeKeywordProposal))
            == 0
        )

    engine.dispose()
