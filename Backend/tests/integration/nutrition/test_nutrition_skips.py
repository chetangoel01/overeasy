"""What a recipe keeps about the ingredients its nutrition could not count.

The notes on the ingredient rows are the cook's copy and read as prose. These
rows are the operator's: which foods the pipeline keeps missing, and on whose
recipes, which is the backlog the curated table will be grown from.
"""

from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from alembic import command
from ladle.db.models import ImportJob, Nutrition, RecipeSlotReservation, SourceVideo
from ladle.db.models import NutritionSkip as NutritionSkipRow
from ladle.db.session import build_engine
from ladle.imports.reservations import ReservationService
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.template_clone import (
    NutritionSkip,
    RecipeTemplate,
    RecipeTemplateCloner,
    record_nutrition_skips,
)
from tests.integration.recipes.test_recipe_service import manual_recipe, seed_user
from tests.integration.test_migrations import alembic_config

NOW = datetime(2026, 9, 7, 12, 0, tzinfo=UTC)


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def partial_template() -> RecipeTemplate:
    """A recipe costed from everything except its spice blend."""

    template = RecipeTemplate.from_recipe(manual_recipe(uuid4()))
    assert template.nutrition is not None
    return template.model_copy(
        update={
            "nutrition": template.nutrition.model_copy(update={"approximate": True}),
            "nutrition_skips": [
                NutritionSkip(
                    index=1,
                    name="garam masala",
                    code="foodNotFound",
                    estimated_grams=Decimal("6"),
                )
            ],
        }
    )


def seed_job(database: Session) -> UUID:
    source_id = uuid4()
    database.add(
        SourceVideo(
            id=source_id,
            platform="youtube",
            platform_video_id="uncounted-spice",
            canonical_url="https://www.youtube.com/watch?v=uncounted-spice",
            public_access_confirmed_at=NOW,
            source_revision="1",
            source_metadata={},
        )
    )
    user_id = seed_user(database)
    job_id = uuid4()
    database.add(
        ImportJob(
            id=job_id,
            user_id=user_id,
            source_video_id=source_id,
            source_url="https://youtu.be/uncounted-spice",
            canonical_url="https://www.youtube.com/watch?v=uncounted-spice",
            source="youtube",
            status="parsing",
            stage="admitted",
            retry_count=0,
            bypass_cache=True,
            idempotency_key=f"skips-{job_id}",
        )
    )
    database.add(
        RecipeSlotReservation(
            id=uuid4(),
            user_id=user_id,
            import_job_id=job_id,
            state="reserved",
            created_at=NOW,
            expires_at=NOW + timedelta(hours=1),
        )
    )
    database.flush()
    return job_id


@pytest.mark.integration
def test_a_partial_recipe_keeps_its_marker_and_the_names_it_skipped(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    cloner = RecipeTemplateCloner(
        clock=FrozenClock(NOW),
        reservations=ReservationService(
            clock=FrozenClock(NOW),
            lifetime=timedelta(hours=1),
        ),
    )

    with Session(engine) as database, database.begin():
        job_id = seed_job(database)

    with Session(engine) as database, database.begin():
        job = database.get(ImportJob, job_id)
        assert job is not None
        cloner.complete_private_for_job(
            database,
            job=job,
            template=partial_template(),
        )
        recipe_id = job.current_recipe_id
        user_id = job.user_id

    assert recipe_id is not None
    with Session(engine) as database:
        nutrition = database.get(Nutrition, recipe_id)
        assert nutrition is not None
        assert nutrition.approximate
        skips = list(
            database.scalars(
                select(NutritionSkipRow).where(NutritionSkipRow.recipe_id == recipe_id)
            )
        )
        assert [(value.ingredient_name, value.code) for value in skips] == [
            ("garam masala", "foodNotFound")
        ]
        assert skips[0].estimated_grams == Decimal("6.000000")

        # The marker rides back out on the wire, which is what puts the "≈"
        # in front of the number the app already shows.
        repository = RecipeRepository()
        stored = repository.find(database, user_id=user_id, recipe_id=recipe_id)
        assert stored is not None
        dto = repository.to_dto(database, stored)
        assert dto.nutrition is not None
        assert dto.nutrition.approximate

    engine.dispose()


@pytest.mark.integration
def test_a_second_run_replaces_the_skips_rather_than_stacking_them(
    clean_postgres_url: str,
) -> None:
    """A re-import that finally matches an ingredient stops reporting it.

    The panel counts what is missing now. Appending would let one recipe
    keep voting for a food it no longer misses.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        recipe = manual_recipe(uuid4())
        RecipeRepository().insert(
            database,
            user_id=user_id,
            recipe=recipe,
            created_at=NOW,
        )
        record_nutrition_skips(
            database,
            recipe_id=recipe.id,
            skips=[
                NutritionSkip(index=1, name="garam masala", code="foodNotFound"),
                NutritionSkip(index=2, name="curry leaves", code="foodNotFound"),
            ],
        )

    with Session(engine) as database, database.begin():
        record_nutrition_skips(
            database,
            recipe_id=recipe.id,
            skips=[NutritionSkip(index=2, name="curry leaves", code="foodNotFound")],
        )

    with Session(engine) as database:
        names = list(
            database.scalars(
                select(NutritionSkipRow.ingredient_name).where(
                    NutritionSkipRow.recipe_id == recipe.id
                )
            )
        )
        assert names == ["curry leaves"]

    engine.dispose()
