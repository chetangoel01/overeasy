"""Discover's keyword shelves, composed by the server from the tags.

The two curated rails are the ranked feed under another order and need no
composition. These are different: which shelves exist at all is a fact about
what the corpus currently holds, so it is a query — and it is the same query
the cook's own filter narrows, because a shelf of dishes their diet rules out
would be an advertisement for food they cannot eat.
"""

import json
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.config import Settings
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
    keywords: tuple[str, ...]


# Ordered most-saved first, so the ranking inside any shelf is this order with
# the dishes that lack the keyword taken out.
#
# The keyword counts this produces are deliberate. Six keywords clear a floor
# of three sources, which is exactly the default cap; `pasta` and `baking` sit
# at two, which is what proves the floor is doing something. The three ties at
# four and the three at three are what prove the vocabulary breaks them.
DISHES = [
    Dish("Lemon Orzo", ("vegetarian",), ("onePot", "weeknight", "pasta")),
    Dish(
        "Chickpea Curry",
        ("vegetarian", "vegan"),
        ("onePot", "weeknight", "mealPrep", "budget"),
    ),
    Dish(
        "Garlic Butter Udon",
        ("vegetarian",),
        ("onePot", "weeknight", "budget", "pasta"),
    ),
    Dish("Sheet-Pan Chicken", (), ("weeknight", "mealPrep", "highProtein", "sheetPan")),
    Dish(
        "Beef Chilli",
        (),
        ("onePot", "mealPrep", "highProtein", "budget", "comfortFood"),
    ),
    Dish("Smash Burgers", (), ("grilling", "comfortFood", "highProtein")),
    Dish("Miso Cookies", ("vegetarian",), ("baking", "dessert")),
    Dish("Banana Bread", ("vegetarian",), ("baking", "budget", "comfortFood")),
]

#: Which dishes carry an unreviewed term. Three of them — enough to clear the
#: floor if a proposal could ever reach the shelf query, which it cannot.
PROPOSAL_DISHES = ("Sheet-Pan Chicken", "Beef Chilli", "Smash Burgers")


def _template(recipe: dict[str, Any], dish: Dish, source_url: str) -> dict[str, Any]:
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
                "name": "flour",
                "preparation": None,
                "orderIndex": 0,
                "uncertainty": None,
            }
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
        "cuisines": ["american"],
        "keywords": list(dish.keywords),
        "keywordProposals": [],
        "notes": [],
        "reviewStatus": "ready",
        "uncertainties": [],
    }


def _seed(engine: Any, recipe: dict[str, Any], savers: list[dict[str, Any]]) -> None:
    """One source per dish, saved by a decreasing number of cooks.

    Every saver's copy carries the source's tags, which is what the import
    path produces: they all come from the same extraction template.
    """

    with Session(engine) as database, database.begin():
        for index, dish in enumerate(DISHES):
            source_id = uuid4()
            cache_id = uuid4()
            source_url = f"https://www.tiktok.com/@mia_cooks/video/{3000 + index}"
            database.add(
                SourceVideo(
                    id=source_id,
                    platform="tiktok",
                    platform_video_id=str(3000 + index),
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
                database.add(
                    Ingredient(
                        id=uuid4(),
                        recipe_id=recipe_id,
                        name="flour",
                        order_index=0,
                    )
                )
                for family, values in (
                    ("diet", dish.diets),
                    ("cuisine", ("american",)),
                    ("keyword", dish.keywords),
                ):
                    for value in values:
                        database.add(
                            RecipeTag(recipe_id=recipe_id, family=family, value=value)
                        )
                if dish.title in PROPOSAL_DISHES:
                    database.add(
                        RecipeKeywordProposal(recipe_id=recipe_id, value="cookout")
                    )


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class Feed:
    """The caller, and a way to ask the same corpus a different question."""

    engine: Any
    client: TestClient
    headers: dict[str, str]
    caller_id: UUID
    client_for: Callable[..., TestClient]

    def shelves(self, query: str = "", **settings: int) -> Any:
        path = f"/v1/recipes/discover/shelves{query}"
        if not settings:
            return self._read(self.client.get(path, headers=self.headers))
        with self.client_for(**settings) as client:
            return self._read(client.get(path, headers=self.headers))

    def _read(self, response: Any) -> Any:
        assert response.status_code == 200, response.text
        return response.json()["shelves"]


@pytest.fixture
def feed(clean_postgres_url: str) -> Iterator[Feed]:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    session_factory = sessionmaker(engine, expire_on_commit=False)

    def client_for(**settings: int) -> TestClient:
        # A second app over the same database and the same signing secret, so
        # a token minted by the first is still good: the floor and the cap are
        # settings, and a test that could not move them would not be testing
        # that they are.
        return TestClient(
            create_app(
                session_factory=session_factory,
                attestation=AttestationService(enforced=False),
                clock=FrozenClock(datetime(2026, 9, 7, 9, 0, tzinfo=UTC)),
                settings=Settings(**settings) if settings else None,
            )
        )

    recipe = json.loads(FIXTURE.read_text())
    with client_for() as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={"installationID": f"shelf-{index}", "attestation": None},
            ).json()
            for index in range(9)
        ]
        _seed(engine, recipe, users[1:])
        yield Feed(
            engine=engine,
            client=client,
            headers={"Authorization": f"Bearer {users[0]['accessToken']}"},
            caller_id=UUID(users[0]["userID"]),
            client_for=client_for,
        )
    engine.dispose()


def _keywords(shelves: Any) -> list[str]:
    return [shelf["keyword"] for shelf in shelves]


def _titles(shelf: Any) -> list[str]:
    return [item["title"] for item in shelf["items"]]


@pytest.mark.integration
def test_shelves_are_ordered_by_how_much_is_behind_them(feed: Feed) -> None:
    """Count first, then the vocabulary, which is how every tag list orders.

    onePot, weeknight and budget each hold four sources; mealPrep,
    highProtein and comfortFood hold three. Within a tie the vocabulary
    decides, so the order does not move between requests.
    """

    assert _keywords(feed.shelves()) == [
        "onePot",
        "weeknight",
        "budget",
        "mealPrep",
        "highProtein",
        "comfortFood",
    ]


@pytest.mark.integration
def test_a_keyword_with_too_little_behind_it_is_not_a_shelf(feed: Feed) -> None:
    """`pasta` and `baking` hold two sources each, and the floor is three."""

    assert "pasta" not in _keywords(feed.shelves())
    assert "baking" not in _keywords(feed.shelves())

    lowered = _keywords(
        feed.shelves(
            discover_shelf_minimum_recipes=2,
            discover_shelf_maximum_count=25,
        )
    )
    assert lowered[-2:] == ["baking", "pasta"]


@pytest.mark.integration
def test_the_cap_keeps_the_best_stocked_shelves(feed: Feed) -> None:
    assert _keywords(feed.shelves(discover_shelf_maximum_count=2)) == [
        "onePot",
        "weeknight",
    ]
    assert feed.shelves(discover_shelf_maximum_count=0) == []


@pytest.mark.integration
def test_a_shelf_is_titled_in_words_rather_than_in_its_raw_value(feed: Feed) -> None:
    shelves = feed.shelves()

    assert [shelf["title"] for shelf in shelves[:3]] == [
        "One pot",
        "Weeknight",
        "Budget",
    ]


@pytest.mark.integration
def test_a_shelf_holds_the_ranked_recipes_that_carry_its_keyword(feed: Feed) -> None:
    shelves = feed.shelves()

    assert _titles(shelves[0]) == [
        "Lemon Orzo",
        "Chickpea Curry",
        "Garlic Butter Udon",
        "Beef Chilli",
    ]


@pytest.mark.integration
def test_the_diet_applies_inside_every_shelf_and_to_which_shelves_exist(
    feed: Feed,
) -> None:
    """A vegetarian sees vegetarian shelves.

    `highProtein` is the case worth watching: three sources carry it and none
    of them is vegetarian, so the shelf does not appear at all rather than
    appearing empty. What survives is filtered card by card as well.
    """

    shelves = feed.shelves("?diet=vegetarian")

    assert _keywords(shelves) == ["onePot", "weeknight", "budget"]
    assert _titles(shelves[0]) == [
        "Lemon Orzo",
        "Chickpea Curry",
        "Garlic Butter Udon",
    ]
    assert _titles(shelves[2]) == [
        "Chickpea Curry",
        "Garlic Butter Udon",
        "Banana Bread",
    ]


@pytest.mark.integration
def test_a_browsing_filter_narrows_the_shelves_the_way_it_narrows_the_list(
    feed: Feed,
) -> None:
    """Keyword and ingredient filters reach the shelves too.

    A cook browsing `onePot` is offered the keywords that travel with it, and
    every card on every one of those shelves is also one-pot. That is the
    conjunction worth asserting: `budget` alone would have held four sources,
    but Banana Bread is not a one-pot dish and does not appear on the shelf a
    one-pot browse produced.
    """

    shelves = feed.shelves("?keyword=onePot")

    assert _keywords(shelves) == ["onePot", "weeknight", "budget"]
    assert _titles(shelves[2]) == [
        "Chickpea Curry",
        "Garlic Butter Udon",
        "Beef Chilli",
    ]
    assert feed.shelves("?ingredient=nothing-has-this") == []


@pytest.mark.integration
def test_an_unreviewed_proposal_never_becomes_a_shelf(feed: Feed) -> None:
    """Three dishes carry "cookout", which would clear the floor twice over.

    It cannot appear, and not because anything filters it out: a proposal
    lives in its own table and the shelf query joins the tag table.
    """

    assert "cookout" not in _keywords(
        feed.shelves(
            discover_shelf_minimum_recipes=1,
            discover_shelf_maximum_count=25,
        )
    )


@pytest.mark.integration
def test_a_shelf_is_one_bounded_page(feed: Feed) -> None:
    shelves = feed.shelves("?limit=2")

    assert _titles(shelves[0]) == ["Lemon Orzo", "Chickpea Curry"]
    assert all(len(shelf["items"]) <= 2 for shelf in shelves)


@pytest.mark.integration
def test_a_source_the_cook_already_saved_does_not_hold_a_shelf_up(
    feed: Feed,
) -> None:
    """The floor counts what the feed would actually serve.

    Discover hides a source this cook has saved. If the count did not hide it
    too, `comfortFood` would still clear three and then arrive with two cards
    — a shelf held up by a recipe already in the cook's own library.
    """

    with Session(feed.engine) as database, database.begin():
        chilli = database.scalar(
            select(Recipe).where(Recipe.title == "Beef Chilli").limit(1)
        )
        assert chilli is not None
        database.add(
            Recipe(
                id=uuid4(),
                user_id=feed.caller_id,
                source_video_id=chilli.source_video_id,
                source_cache_id=chilli.source_cache_id,
                title=chilli.title,
                description=chilli.description,
                creator_name=chilli.creator_name,
                source="tiktok",
                original_url=chilli.original_url,
                servings=Decimal(4),
                favorite=False,
                review_status="ready",
                revision=1,
                created_at=datetime(2026, 9, 7, 8, tzinfo=UTC),
                updated_at=datetime(2026, 9, 7, 8, tzinfo=UTC),
            )
        )

    shelves = feed.shelves()

    assert _keywords(shelves) == ["weeknight", "onePot", "budget"]
    assert all("Beef Chilli" not in _titles(shelf) for shelf in shelves)


@pytest.mark.integration
def test_the_shelves_path_is_not_read_as_a_source_id(feed: Feed) -> None:
    """`/discover/{source_video_id}` is declared after this route on purpose.

    The other way round, "shelves" is parsed as a UUID and a path that exists
    answers 422.
    """

    with feed.client_for() as client:
        response = client.get("/v1/recipes/discover/shelves", headers=feed.headers)

    assert response.status_code == 200
