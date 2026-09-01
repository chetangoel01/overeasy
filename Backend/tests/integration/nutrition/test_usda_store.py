import httpx
import pytest

from alembic import command
from ladle.db.session import build_engine, build_session_factory
from ladle.nutrition.store import DatabaseUSDAPayloadStore
from ladle.nutrition.usda import USDAClient
from tests.integration.test_migrations import alembic_config

SEARCH = {
    "foods": [
        {
            "fdcId": 170923,
            "description": "Spices, cumin seed",
            "dataType": "SR Legacy",
            "score": 700.0,
        }
    ]
}
DETAIL = {
    "fdcId": 170923,
    "description": "Spices, cumin seed",
    "dataType": "SR Legacy",
    "foodNutrients": [
        {"nutrient": {"id": 1008, "unitName": "kcal"}, "amount": 375},
        {"nutrient": {"id": 1003, "unitName": "g"}, "amount": 17.81},
        {"nutrient": {"id": 1004, "unitName": "g"}, "amount": 22.27},
        {"nutrient": {"id": 1005, "unitName": "g"}, "amount": 44.24},
    ],
    "foodPortions": [],
}


def _client(store: DatabaseUSDAPayloadStore, calls: list[str]) -> USDAClient:
    def respond(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json=SEARCH)
        return httpx.Response(200, json=DETAIL)

    return USDAClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key="usda-test-key",
        base_url="https://api.nal.usda.gov/fdc/v1",
        store=store,
    )


@pytest.mark.integration
def test_stored_payloads_serve_later_lookups_without_touching_usda(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    sessions = build_session_factory(build_engine(clean_postgres_url))
    store = DatabaseUSDAPayloadStore(session_factory=sessions)

    calls: list[str] = []
    first = _client(store, calls).candidates("cumin seeds")
    assert [food.fdc_id for food in first] == [170923]
    assert len(calls) == 2

    # A separate client, as a second worker would be: the in-process LRU is
    # empty, so anything it returns came out of the database.
    later_calls: list[str] = []
    second = _client(store, later_calls).candidates("cumin seeds")

    assert [food.fdc_id for food in second] == [170923]
    assert second[0].calories_per_100g == first[0].calories_per_100g
    assert later_calls == []


@pytest.mark.integration
def test_saving_the_same_food_twice_refreshes_rather_than_conflicts(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    sessions = build_session_factory(build_engine(clean_postgres_url))
    store = DatabaseUSDAPayloadStore(session_factory=sessions)

    store.save_food(170923, DETAIL)
    store.save_food(170923, {**DETAIL, "description": "Spices, cumin seed, ground"})
    store.save_search("cumin seeds", SEARCH)
    store.save_search("cumin seeds", {"foods": []})

    stored = store.food(170923)
    assert stored is not None
    assert stored["description"] == "Spices, cumin seed, ground"
    assert store.search("cumin seeds") == {"foods": []}


@pytest.mark.integration
def test_an_unknown_query_reports_nothing_stored(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    sessions = build_session_factory(build_engine(clean_postgres_url))
    store = DatabaseUSDAPayloadStore(session_factory=sessions)

    assert store.search("nothing here") is None
    assert store.food(1) is None
