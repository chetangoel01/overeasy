"""The one-off command that gives already-imported recipes a total time.

The prompt bump only helps recipes imported after it, and an extraction
cache keyed on the prompt version means the library on the phone keeps its
"—" until every source is re-imported. This asks the configured provider
the timing question alone, against what is already stored, and writes the
answer through the path an edit takes so the device actually receives it.
"""

import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import select
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session

from alembic import command
from ladle.admin.backfill_times import (
    RecipeTimeEvidence,
    TimeBackfillService,
    TimeEstimate,
    render_table,
)
from ladle.contracts.recipes import RecipeDTO, RecipeReviewStatus
from ladle.db.models import Recipe, RecipeImage, User, UserSyncState
from ladle.db.session import build_engine
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService
from ladle.sync.service import RecipeSyncService
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[4] / "Contracts" / "Fixtures" / "recipe-ready.json"
NOW = datetime(2026, 9, 2, 9, 0, tzinfo=UTC)


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeEstimator:
    """Stands in for the configured extraction provider."""

    minutes: int | None
    calls: list[RecipeTimeEvidence] = field(default_factory=list)

    def estimate(
        self,
        *,
        model: str,
        max_tokens: int,
        evidence: RecipeTimeEvidence,
    ) -> TimeEstimate | None:
        del model, max_tokens
        self.calls.append(evidence)
        if self.minutes is None:
            return None
        return TimeEstimate(total_minutes=self.minutes)


def untimed_recipe(recipe_id: UUID, *, title: str = "Lemon Orzo") -> RecipeDTO:
    """recipe-ready.json with its times stripped and its ids made unique."""

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
            # The shape the library is actually in: one 10-minute step timer
            # and not a stated minute anywhere.
            "preparationMinutes": None,
            "cookingMinutes": None,
            "totalMinutes": None,
        }
    )
    return RecipeDTO.model_validate(value)


def seed_user(database: Session) -> UUID:
    user_id = uuid4()
    database.add(User(id=user_id, kind="guest", created_at=NOW))
    database.flush()
    database.add(UserSyncState(user_id=user_id, next_sequence=1))
    database.flush()
    return user_id


def backfill(estimator: FakeEstimator) -> TimeBackfillService:
    repository = RecipeRepository(object_url=lambda key: f"https://signed.test/{key}")
    return TimeBackfillService(
        client=estimator,
        model_id="test-model",
        max_tokens=1024,
        recipes=RecipeService(clock=FrozenClock(NOW), repository=repository),
        repository=repository,
    )


def seed(engine: Engine, *, recipe: RecipeDTO) -> UUID:
    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        RecipeService(clock=FrozenClock(NOW)).upsert(
            database,
            user_id=user_id,
            recipe=recipe,
            base_revision=0,
        )
    return user_id


@pytest.mark.integration
def test_dry_run_computes_the_table_without_writing(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed(engine, recipe=untimed_recipe(recipe_id))
    estimator = FakeEstimator(minutes=25)

    with Session(engine) as database:
        rows = backfill(estimator).run(database, limit=None, dry_run=True)
        database.rollback()

    assert [row.proposed_minutes for row in rows] == [25]
    assert [row.timer_minutes for row in rows] == [10]
    assert rows[0].action == "would set 25 min"
    # The provider was asked, so the table is computed rather than guessed.
    assert len(estimator.calls) == 1
    assert estimator.calls[0].steps[0].timers[0].duration_seconds == 600
    assert "25" in render_table(rows)

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.total_minutes is None
        assert stored.revision == 1

    engine.dispose()


@pytest.mark.integration
def test_a_real_run_labels_the_estimate_and_is_idempotent(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed(engine, recipe=untimed_recipe(recipe_id))
    # An image already copied into object storage: the write goes through
    # the whole recipe graph, and must not turn a stored key into a URL.
    with Session(engine) as database, database.begin():
        image = database.scalars(
            select(RecipeImage).where(RecipeImage.recipe_id == recipe_id)
        ).one()
        image.object_key = "recipes/lemon-orzo.jpg"
        image.remote_url = None
    estimator = FakeEstimator(minutes=25)

    with Session(engine) as database, database.begin():
        rows = backfill(estimator).run(database, limit=None, dry_run=False)
    assert [row.action for row in rows] == ["set 25 min"]

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.total_minutes == 25
        assert stored.revision == 2
        # An estimate is a caveat, never a trip to Check details.
        assert stored.review_status == RecipeReviewStatus.READY.value
        dto = RecipeRepository(
            object_url=lambda key: f"https://signed.test/{key}"
        ).to_dto(database, stored)
        assert [value.field for value in dto.uncertainties] == ["total_minutes"]
        assert "estimated from the method" in dto.uncertainties[0].reason
        image = database.scalars(
            select(RecipeImage).where(RecipeImage.recipe_id == recipe_id)
        ).one()
        assert image.object_key == "recipes/lemon-orzo.jpg"
        assert image.remote_url is None

    repeat = FakeEstimator(minutes=25)
    with Session(engine) as database, database.begin():
        repeated = backfill(repeat).run(database, limit=None, dry_run=False)
    assert repeated == []
    assert repeat.calls == []

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.revision == 2

    engine.dispose()


@pytest.mark.integration
def test_an_estimate_under_the_step_timers_is_refused(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    seed(engine, recipe=untimed_recipe(recipe_id))
    estimator = FakeEstimator(minutes=5)

    with Session(engine) as database, database.begin():
        rows = backfill(estimator).run(database, limit=None, dry_run=False)

    assert rows[0].proposed_minutes == 5
    assert rows[0].action == "skipped: under the 10 min floor"

    with Session(engine) as database:
        stored = database.get(Recipe, recipe_id)
        assert stored is not None
        assert stored.total_minutes is None
        assert stored.revision == 1

    engine.dispose()


@pytest.mark.integration
def test_a_backfilled_recipe_arrives_in_the_next_sync_page(
    clean_postgres_url: str,
) -> None:
    """The point of writing through the edit path.

    A recipe whose row is updated in place never reaches the phone: the
    device pages `recipe_changes` from its cursor, so the estimate has to
    arrive as a change at a new revision or it stays invisible.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipe_id = uuid4()
    user_id = seed(engine, recipe=untimed_recipe(recipe_id))
    sync = RecipeSyncService()

    with Session(engine) as database:
        caught_up = sync.page(database, user_id=user_id, cursor=0, limit=50)
    cursor = caught_up.next_cursor

    with Session(engine) as database, database.begin():
        backfill(FakeEstimator(minutes=25)).run(database, limit=None, dry_run=False)

    with Session(engine) as database:
        delta = sync.page(database, user_id=user_id, cursor=cursor, limit=50)

    assert [change.recipe_id for change in delta.changes] == [recipe_id]
    assert delta.changes[0].recipe_revision == 2
    assert delta.changes[0].recipe is not None
    assert delta.changes[0].recipe.total_minutes == 25
    assert [value.field for value in delta.changes[0].recipe.uncertainties] == [
        "total_minutes"
    ]

    engine.dispose()


@pytest.mark.integration
def test_limit_stops_the_run_and_timed_recipes_are_never_asked(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    untimed = [uuid4(), uuid4()]
    timed = uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        service = RecipeService(clock=FrozenClock(NOW))
        for index, recipe_id in enumerate(untimed):
            service.upsert(
                database,
                user_id=user_id,
                recipe=untimed_recipe(recipe_id, title=f"Untimed {index}"),
                base_revision=0,
            )
        service.upsert(
            database,
            user_id=user_id,
            recipe=untimed_recipe(timed, title="Timed").model_copy(
                update={"total_minutes": 40}
            ),
            base_revision=0,
        )

    estimator = FakeEstimator(minutes=25)
    with Session(engine) as database, database.begin():
        rows = backfill(estimator).run(database, limit=1, dry_run=False)

    assert len(rows) == 1
    assert rows[0].recipe_id in untimed
    assert len(estimator.calls) == 1

    with Session(engine) as database:
        stored = database.get(Recipe, timed)
        assert stored is not None
        assert stored.total_minutes == 40
        assert stored.revision == 1

    engine.dispose()
