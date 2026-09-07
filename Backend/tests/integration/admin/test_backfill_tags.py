"""The one-off command that tags a library imported before tags existed.

The extraction cache is keyed on the prompt version, so the new question is
never asked of a recipe already stored. This re-acquires each source, re-runs
extraction, and writes back the tags alone — leaving the cook's own copy of
everything else exactly as they have it.
"""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4, uuid5

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session

from alembic import command
from ladle.acquisition.errors import PrivateOrDeleted
from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.admin.backfill_tags import TagBackfillService, render_table
from ladle.contracts.recipes import RecipeDTO, RecipeReviewStatus, RecipeSource
from ladle.contracts.tags import CuisineTag, DietTag, RecipeKeyword
from ladle.db.models import Recipe, RecipeChange, SourceVideo, User, UserSyncState
from ladle.db.session import build_engine
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateStep,
)
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[4] / "Contracts" / "Fixtures" / "recipe-ready.json"
NOW = datetime(2026, 9, 7, 9, 0, tzinfo=UTC)


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeAcquirer:
    """Stands in for the provider chain; counts what it was asked for."""

    calls: list[UUID]
    fail: bool = False

    def check_public(self, source: SourceVideoDescriptor, *, job_id: UUID) -> bool:
        return True

    def refresh_counts(self, source: SourceVideoDescriptor, *, job_id: UUID) -> object:
        raise NotImplementedError

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        self.calls.append(source.source_video_id)
        if self.fail:
            raise PrivateOrDeleted("the creator took it down")
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title="Lemon Orzo",
            description="",
            transcript=[
                TextEvidence(
                    text="Cook the orzo.",
                    start_seconds=0,
                    end_seconds=2,
                    provenance="fake",
                    generated=False,
                )
            ],
            visual_observations=[],
            diagnostics=[],
        )


@dataclass
class FakeExtractor:
    contract_version: str = "v1"
    prompt_version: str = "fake-tags-v1"
    model_id: str = "fake"
    tagged: bool = True

    def extract(
        self,
        context: AcquiredVideoContext,
        *,
        job_id: UUID,
    ) -> RecipeTemplate:
        return RecipeTemplate(
            title="A second opinion nobody asked for",
            description="",
            source=RecipeSource(context.source.platform),
            original_url=context.source.canonical_url,
            servings=Decimal("4"),
            ingredients=[TemplateIngredient(name="orzo", order_index=0)],
            steps=[TemplateStep(order_index=0, instruction="Cook.")],
            diets=[DietTag.VEGETARIAN] if self.tagged else [],
            cuisines=[CuisineTag.MEDITERRANEAN] if self.tagged else [],
            keywords=[RecipeKeyword.ONE_POT] if self.tagged else [],
            keyword_proposals=["lemony"] if self.tagged else [],
            review_status=RecipeReviewStatus.READY,
        )


def stored_recipe(recipe_id: UUID, *, title: str = "Lemon Orzo") -> RecipeDTO:
    """recipe-ready.json, untagged and with its child ids made unique."""

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
            child_ids[value_id] for value_id in step["ingredientIDs"]
        ]
        for timer in step["timers"]:
            timer["id"] = str(uuid5(recipe_id, timer["id"]))
    for nutrient in value["nutrition"]["otherNutrients"]:
        nutrient["id"] = str(uuid5(recipe_id, nutrient["id"]))
    value.update(
        {
            "id": str(recipe_id),
            "title": title,
            # Seeded through the manual-create path, which is the only way to
            # insert a recipe without an import job; `seed` then attaches the
            # source video the way an import would have.
            "source": "other",
            "originalURL": f"https://manual.ladle.local/{recipe_id}",
            "diets": [],
            "cuisines": [],
            "keywords": [],
            "keywordProposals": [],
        }
    )
    return RecipeDTO.model_validate(value)


def seed(engine, *, savers: int = 1) -> tuple[UUID, list[UUID]]:
    """One source video saved by `savers` cooks, none of them tagged."""

    service = RecipeService(clock=FrozenClock(NOW))
    source_id = uuid4()
    recipe_ids: list[UUID] = []
    with Session(engine) as database, database.begin():
        database.add(
            SourceVideo(
                id=source_id,
                platform="tiktok",
                platform_video_id="backfill-tags",
                canonical_url="https://www.tiktok.com/@mia_cooks/video/9001",
                source_revision="1",
                source_metadata={},
            )
        )
        database.flush()
        for index in range(savers):
            user_id = uuid4()
            database.add(User(id=user_id, kind="guest", created_at=NOW))
            database.flush()
            database.add(UserSyncState(user_id=user_id, next_sequence=1))
            database.flush()
            recipe_id = uuid4()
            recipe_ids.append(recipe_id)
            stored = service.upsert(
                database,
                user_id=user_id,
                recipe=stored_recipe(recipe_id, title=f"Lemon Orzo {index}"),
                base_revision=0,
            )
            database.get(Recipe, stored.id).source_video_id = source_id
    return source_id, recipe_ids


def build(engine, **overrides) -> tuple[TagBackfillService, FakeAcquirer]:
    acquirer = overrides.pop("acquirer", None) or FakeAcquirer(calls=[])
    repository = RecipeRepository()
    return (
        TagBackfillService(
            acquirer=acquirer,
            extractor=overrides.pop("extractor", None) or FakeExtractor(),
            recipes=RecipeService(clock=FrozenClock(NOW), repository=repository),
            repository=repository,
            pause_seconds=0,
        ),
        acquirer,
    )


@pytest.mark.integration
def test_a_dry_run_reports_what_it_would_do_and_writes_nothing(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    _, recipe_ids = seed(engine)
    service, _ = build(engine)

    with Session(engine) as database:
        rows = service.run(database, limit=None, dry_run=True)
        database.rollback()

    assert [row.action for row in rows] == ["would tag"]
    assert rows[0].diets == ("vegetarian",)
    assert rows[0].cuisines == ("mediterranean",)
    assert rows[0].keywords == ("onePot",)
    assert rows[0].proposals == ("lemony",)

    table = render_table(rows)
    assert "would tag" in table
    assert "lemony" in table

    with Session(engine) as database:
        after = RecipeRepository().to_dto(database, database.get(Recipe, recipe_ids[0]))
    assert after.diets == []
    assert after.revision == 1

    engine.dispose()


@pytest.mark.integration
def test_a_real_run_writes_only_the_tags_and_bumps_the_revision(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    _, recipe_ids = seed(engine)
    service, _ = build(engine)

    with Session(engine) as database, database.begin():
        rows = service.run(database, limit=None, dry_run=False)

    assert [row.action for row in rows] == ["tagged"]

    with Session(engine) as database:
        after = RecipeRepository().to_dto(database, database.get(Recipe, recipe_ids[0]))
        changes = database.scalars(
            select(RecipeChange).order_by(RecipeChange.sequence)
        ).all()

    assert after.diets == [DietTag.VEGETARIAN]
    assert after.keywords == [RecipeKeyword.ONE_POT]
    assert after.keyword_proposals == ["lemony"]
    # The cook's own copy is untouched: the fresh extraction's title, its
    # single ingredient and its one step are all discarded.
    assert after.title == "Lemon Orzo 0"
    assert len(after.ingredients) == 2
    assert after.nutrition is not None
    # Revision bumped and a change row emitted, or the phone never learns.
    assert after.revision == 2
    assert [change.recipe_revision for change in changes] == [1, 2]

    engine.dispose()


@pytest.mark.integration
def test_one_acquisition_serves_every_saver_of_a_source(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    source_id, _ = seed(engine, savers=3)
    service, acquirer = build(engine)

    with Session(engine) as database, database.begin():
        rows = service.run(database, limit=None, dry_run=False)

    assert [row.action for row in rows] == ["tagged"] * 3
    assert acquirer.calls == [source_id]

    engine.dispose()


@pytest.mark.integration
def test_a_source_that_cannot_be_acquired_is_named_not_counted(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    seed(engine)
    service, _ = build(engine, acquirer=FakeAcquirer(calls=[], fail=True))

    with Session(engine) as database:
        rows = service.run(database, limit=None, dry_run=True)
        database.rollback()

    assert [row.action for row in rows] == ["skipped: PrivateOrDeleted"]

    engine.dispose()


@pytest.mark.integration
def test_an_extraction_with_no_tags_is_not_a_write(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    seed(engine)
    service, _ = build(engine, extractor=FakeExtractor(tagged=False))

    with Session(engine) as database, database.begin():
        rows = service.run(database, limit=None, dry_run=False)

    assert [row.action for row in rows] == ["skipped: the model returned no tags"]

    engine.dispose()


@pytest.mark.integration
def test_a_manual_recipe_is_reported_rather_than_skipped_in_silence(
    clean_postgres_url: str,
) -> None:
    """A recipe typed by hand has no video to re-read; say so."""

    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    seed(engine)
    manual_id = uuid4()
    with Session(engine) as database, database.begin():
        user_id = uuid4()
        database.add(User(id=user_id, kind="guest", created_at=NOW))
        database.flush()
        database.add(UserSyncState(user_id=user_id, next_sequence=1))
        database.flush()
        RecipeService(clock=FrozenClock(NOW)).upsert(
            database,
            user_id=user_id,
            recipe=stored_recipe(manual_id, title="Hand typed"),
            base_revision=0,
        )
    service, _ = build(engine)

    with Session(engine) as database:
        rows = service.run(database, limit=None, dry_run=True)
        database.rollback()

    assert ("Hand typed", "skipped: no source video") in [
        (row.title, row.action) for row in rows
    ]

    engine.dispose()


@pytest.mark.integration
def test_an_empty_corpus_says_so(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    service, _ = build(engine)

    with Session(engine) as database:
        rows = service.run(database, limit=None, dry_run=True)

    assert rows == []
    assert render_table(rows) == "No recipes to tag."

    engine.dispose()
