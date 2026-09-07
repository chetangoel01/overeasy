"""Filtering the Discover and Watch feed on the server, page by page.

Watch is this endpoint without a paging pin — the repository's `discover`
docstring says so — which is why one filter here covers both tabs.
"""

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.db.models import (
    ExtractionCache,
    Ingredient,
    Recipe,
    RecipeKeywordProposal,
    RecipeTag,
    SourceVideo,
)
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[3] / "Contracts" / "Fixtures" / "recipe-ready.json"


@dataclass(frozen=True)
class Dish:
    title: str
    diets: tuple[str, ...]
    cuisines: tuple[str, ...]
    keywords: tuple[str, ...]
    ingredients: tuple[str, ...]


# Ordered most-saved first, so the unfiltered popular feed is exactly this
# order and every assertion below can be read as "which of these survive".
DISHES = [
    Dish(
        title="Lemon Orzo",
        diets=("vegetarian",),
        cuisines=("mediterranean",),
        keywords=("onePot", "weeknight"),
        ingredients=("orzo", "lemon"),
    ),
    Dish(
        title="Lemon Chicken",
        diets=("glutenFree",),
        cuisines=("mediterranean",),
        keywords=("weeknight",),
        ingredients=("chicken thighs", "lemon"),
    ),
    Dish(
        title="Garlic Butter Udon",
        diets=("vegetarian",),
        cuisines=("japanese",),
        keywords=("onePot",),
        ingredients=("udon noodles", "garlic"),
    ),
    Dish(
        title="Chickpea Curry",
        diets=("vegetarian", "vegan", "glutenFree"),
        cuisines=("indian",),
        keywords=("onePot", "mealPrep"),
        ingredients=("chickpeas", "coconut milk"),
    ),
    Dish(
        title="Smash Burgers",
        diets=(),
        cuisines=("american",),
        keywords=("grilling",),
        ingredients=("beef mince", "brioche buns"),
    ),
    Dish(
        title="Chicken Katsu",
        diets=(),
        cuisines=("japanese",),
        keywords=("weeknight",),
        ingredients=("chicken breast", "panko breadcrumbs"),
    ),
]


def _template(recipe: dict, dish: Dish, source_url: str) -> dict:
    return {
        "title": dish.title,
        "description": recipe["description"],
        "creatorName": "@mia_cooks",
        "source": "tiktok",
        "originalURL": source_url,
        "servings": "4",
        "ingredients": [
            {
                "quantityText": "1 cup",
                "normalizedQuantity": "1",
                "unit": "cup",
                "name": name,
                "preparation": None,
                "orderIndex": index,
                "uncertainty": None,
            }
            for index, name in enumerate(dish.ingredients)
        ],
        "steps": [
            {
                "orderIndex": 0,
                "instruction": "Cook until tender.",
                "ingredientIndexes": [0],
                "timers": [],
                "sourceStartSeconds": None,
                "sourceEndSeconds": None,
                "uncertainty": None,
            }
        ],
        "diets": list(dish.diets),
        "cuisines": list(dish.cuisines),
        "keywords": list(dish.keywords),
        "keywordProposals": [],
        "notes": [],
        "reviewStatus": "ready",
        "uncertainties": [],
    }


def _seed(engine, recipe: dict, savers: list[dict]) -> None:
    """One source per dish, saved by a decreasing number of cooks.

    Every saver's copy carries the source's tags, which is what the import
    path produces: they all come from the same extraction template.
    """
    with Session(engine) as database, database.begin():
        for index, dish in enumerate(DISHES):
            source_id = uuid4()
            cache_id = uuid4()
            source_url = f"https://www.tiktok.com/@mia_cooks/video/{2000 + index}"
            database.add(
                SourceVideo(
                    id=source_id,
                    platform="tiktok",
                    platform_video_id=str(2000 + index),
                    canonical_url=source_url,
                    public_access_confirmed_at=datetime(2026, 9, 6, 12, tzinfo=UTC),
                    source_revision="1",
                    source_metadata={},
                )
            )
            database.flush()
            database.add(
                ExtractionCache(
                    id=cache_id,
                    source_video_id=source_id,
                    source_revision="1",
                    contract_version="v1",
                    prompt_version="recipe-test",
                    model_id="test-model",
                    template_json=_template(recipe, dish, source_url),
                    review_status="ready",
                    thumbnail_remote_url=recipe["images"][0]["remoteURL"],
                )
            )
            for rank, saver in enumerate(savers[: len(DISHES) - index]):
                recipe_id = uuid4()
                database.add(
                    Recipe(
                        id=recipe_id,
                        user_id=UUID(saver["userID"]),
                        source_video_id=source_id,
                        source_cache_id=cache_id,
                        title=dish.title,
                        description=recipe["description"],
                        creator_name="@mia_cooks",
                        source="tiktok",
                        original_url=source_url,
                        servings=Decimal(4),
                        favorite=False,
                        review_status="ready",
                        revision=1,
                        created_at=datetime(2026, 9, 6, 12, rank, tzinfo=UTC),
                        updated_at=datetime(2026, 9, 6, 12, rank, tzinfo=UTC),
                    )
                )
                database.flush()
                for order, name in enumerate(dish.ingredients):
                    database.add(
                        Ingredient(
                            id=uuid4(),
                            recipe_id=recipe_id,
                            name=name,
                            order_index=order,
                        )
                    )
                for family, values in (
                    ("diet", dish.diets),
                    ("cuisine", dish.cuisines),
                    ("keyword", dish.keywords),
                ):
                    for value in values:
                        database.add(
                            RecipeTag(
                                recipe_id=recipe_id,
                                family=family,
                                value=value,
                            )
                        )
                # An unreviewed term on every copy of one dish. Nothing may
                # ever filter on it.
                if dish.title == "Smash Burgers":
                    database.add(
                        RecipeKeywordProposal(
                            recipe_id=recipe_id,
                            value="cookout",
                        )
                    )


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.fixture
def discover(clean_postgres_url: str):
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
        clock=FrozenClock(datetime(2026, 9, 7, 9, 0, tzinfo=UTC)),
    )
    recipe = json.loads(FIXTURE.read_text())
    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={
                    "installationID": f"discover-filter-{index}",
                    "attestation": None,
                },
            ).json()
            for index in range(7)
        ]
        _seed(engine, recipe, users[1:])
        headers = {"Authorization": f"Bearer {users[0]['accessToken']}"}

        def get(query: str = ""):
            response = client.get(f"/v1/recipes/discover{query}", headers=headers)
            return response

        yield get
    engine.dispose()


def _titles(response) -> list[str]:
    assert response.status_code == 200, response.text
    return [item["title"] for item in response.json()["items"]]


@pytest.mark.integration
def test_the_unfiltered_feed_is_every_dish(discover) -> None:
    assert _titles(discover()) == [dish.title for dish in DISHES]


@pytest.mark.integration
def test_one_diet_keeps_only_the_dishes_that_satisfy_it(discover) -> None:
    assert _titles(discover("?diet=vegetarian")) == [
        "Lemon Orzo",
        "Garlic Butter Udon",
        "Chickpea Curry",
    ]


@pytest.mark.integration
def test_several_diets_all_have_to_hold(discover) -> None:
    """A cook who avoids gluten and meat wants dishes that are both."""

    assert _titles(discover("?diet=vegetarian&diet=glutenFree")) == ["Chickpea Curry"]


@pytest.mark.integration
def test_cuisines_widen_the_browse_rather_than_narrowing_it(discover) -> None:
    assert _titles(discover("?cuisine=japanese")) == [
        "Garlic Butter Udon",
        "Chicken Katsu",
    ]
    assert _titles(discover("?cuisine=japanese&cuisine=indian")) == [
        "Garlic Butter Udon",
        "Chickpea Curry",
        "Chicken Katsu",
    ]


@pytest.mark.integration
def test_a_keyword_narrows_the_feed(discover) -> None:
    assert _titles(discover("?keyword=onePot")) == [
        "Lemon Orzo",
        "Garlic Butter Udon",
        "Chickpea Curry",
    ]


@pytest.mark.integration
def test_ingredient_inclusion_answers_only_recipes_with_chicken(discover) -> None:
    assert _titles(discover("?ingredient=chicken")) == [
        "Lemon Chicken",
        "Chicken Katsu",
    ]


@pytest.mark.integration
def test_several_ingredients_all_have_to_be_present(discover) -> None:
    assert _titles(discover("?ingredient=chicken&ingredient=lemon")) == [
        "Lemon Chicken"
    ]


@pytest.mark.integration
def test_families_compose(discover) -> None:
    assert _titles(discover("?diet=glutenFree&ingredient=chicken")) == ["Lemon Chicken"]
    assert _titles(discover("?diet=vegetarian&cuisine=japanese&keyword=onePot")) == [
        "Garlic Butter Udon"
    ]


@pytest.mark.integration
def test_paging_walks_the_filtered_feed_and_stops(discover) -> None:
    first = discover("?diet=vegetarian&limit=2")
    assert _titles(first) == ["Lemon Orzo", "Garlic Butter Udon"]
    assert first.json()["hasMore"] is True
    assert first.json()["nextCursor"] == 2

    second = discover("?diet=vegetarian&limit=2&cursor=2")
    assert _titles(second) == ["Chickpea Curry"]
    assert second.json()["hasMore"] is False
    assert second.json()["nextCursor"] == 3


@pytest.mark.integration
def test_a_filter_that_matches_nothing_is_an_empty_page(discover) -> None:
    response = discover("?diet=vegan&cuisine=american")
    assert _titles(response) == []
    assert response.json()["hasMore"] is False


@pytest.mark.integration
def test_a_value_outside_the_vocabulary_is_refused(discover) -> None:
    assert discover("?diet=keto").status_code == 422
    assert discover("?cuisine=martian").status_code == 422
    assert discover("?keyword=onePan").status_code == 422


@pytest.mark.integration
def test_an_unreviewed_proposal_cannot_be_filtered_on(discover) -> None:
    """`cookout` is stored against Smash Burgers, and is not a keyword."""

    assert discover("?keyword=cookout").status_code == 422
