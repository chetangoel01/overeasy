import copy
import json
from decimal import Decimal
from pathlib import Path

import httpx
import pytest

from ladle.acquisition.errors import (
    MalformedProviderResponse,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
)
from ladle.nutrition.usda import USDAClient

FIXTURES = Path(__file__).parents[2] / "fixtures" / "providers" / "usda"
SEARCH = json.loads((FIXTURES / "search.json").read_text())
FOOD = json.loads((FIXTURES / "food.json").read_text())


def client(
    handler,
    *,
    maximum_candidates: int = 3,
    maximum_cache_entries: int = 512,
) -> USDAClient:
    return USDAClient(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        api_key="usda-test-key",
        base_url="https://api.nal.usda.gov/fdc/v1",
        maximum_candidates=maximum_candidates,
        maximum_cache_entries=maximum_cache_entries,
    )


def detail_for(fdc_id: int) -> dict:
    value = copy.deepcopy(FOOD)
    row = next(row for row in SEARCH["foods"] if row["fdcId"] == fdc_id)
    value.update(
        {
            "fdcId": fdc_id,
            "description": row["description"],
            "dataType": row["dataType"],
        }
    )
    return value


def test_candidates_prefer_generic_foods_and_parse_nutrients_and_portions() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.url.params["api_key"] == "usda-test-key"
        if request.url.path.endswith("/foods/search"):
            payload = json.loads(request.content)
            assert payload["query"] == "chickpeas canned drained"
            assert payload["dataType"] == [
                "Foundation",
                "SR Legacy",
                "Survey (FNDDS)",
                "Branded",
            ]
            return httpx.Response(200, json=SEARCH)
        fdc_id = int(request.url.path.rsplit("/", 1)[-1])
        return httpx.Response(200, json=detail_for(fdc_id))

    foods = client(respond).candidates("chickpeas canned drained")

    assert [food.fdc_id for food in foods] == [2644288, 173800, 999001]
    assert [food.search_rank for food in foods] == [0, 1, 2]
    assert foods[0].calories_per_100g == Decimal("132.972")
    assert foods[0].protein_grams_per_100g == Decimal("7.01875")
    assert foods[0].carbohydrate_grams_per_100g == Decimal("20.32025")
    assert foods[0].fat_grams_per_100g == Decimal("3.096")
    assert foods[0].portions[1].measure_unit == "cup"
    assert foods[0].portions[1].gram_weight == 164
    assert len(requests) == 4


def test_exact_normalized_query_is_cached_in_process() -> None:
    calls = 0

    def respond(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json={"foods": [SEARCH["foods"][1]]})
        return httpx.Response(200, json=FOOD)

    usda = client(respond)

    first = usda.candidates("  Chickpeas   CANNED drained ")
    second = usda.candidates("chickpeas canned drained")

    assert first == second
    assert calls == 2


@pytest.mark.parametrize(
    ("nutrient_id", "bad_unit"),
    [(2048, "kJ"), (1003, "mg"), (1004, "mg"), (1005, "mg")],
)
def test_wrong_required_nutrient_units_are_not_guessed(
    nutrient_id: int,
    bad_unit: str,
) -> None:
    detail = copy.deepcopy(FOOD)
    nutrient = next(
        value
        for value in detail["foodNutrients"]
        if value["nutrient"]["id"] == nutrient_id
    )
    nutrient["nutrient"]["unitName"] = bad_unit

    def respond(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json={"foods": [SEARCH["foods"][1]]})
        return httpx.Response(200, json=detail)

    assert client(respond).candidates("chickpeas") == []


def test_missing_required_macro_returns_no_candidate() -> None:
    detail = copy.deepcopy(FOOD)
    detail["foodNutrients"] = [
        value for value in detail["foodNutrients"] if value["nutrient"]["id"] != 1005
    ]

    def respond(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json={"foods": [SEARCH["foods"][1]]})
        return httpx.Response(200, json=detail)

    assert client(respond).candidates("chickpeas") == []


def test_stale_search_result_with_missing_detail_is_skipped() -> None:
    rows = [SEARCH["foods"][0], SEARCH["foods"][1]]

    def respond(request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/foods/search"):
            return httpx.Response(200, json={"foods": rows})
        if request.url.path.endswith(str(rows[1]["fdcId"])):
            return httpx.Response(404)
        return httpx.Response(200, json=detail_for(rows[0]["fdcId"]))

    foods = client(respond).candidates("chickpeas")

    assert [value.fdc_id for value in foods] == [rows[0]["fdcId"]]
    assert foods[0].search_rank == 1


def test_transport_timeout_is_typed_without_guessing() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("timeout", request=request)

    with pytest.raises(ProviderTransientError):
        client(respond).candidates("chickpeas")


@pytest.mark.parametrize(
    ("status", "error_type"),
    [
        (401, ProviderAuthenticationError),
        (429, ProviderQuotaError),
        (503, ProviderTransientError),
    ],
)
def test_api_errors_are_typed_without_exposing_the_key(
    status: int,
    error_type: type[Exception],
) -> None:
    with pytest.raises(error_type) as error:
        client(lambda _: httpx.Response(status, json={"error": "down"})).candidates(
            "chickpeas"
        )

    assert "usda-test-key" not in str(error.value)


def test_malformed_search_response_is_typed() -> None:
    with pytest.raises(MalformedProviderResponse):
        client(lambda _: httpx.Response(200, json={"foods": "not-a-list"})).candidates(
            "chickpeas"
        )


def test_the_search_cache_is_bounded_and_evicts_the_oldest_entry() -> None:
    """The worker process lives for weeks and the keys are model-generated
    ingredient phrasings — an effectively unbounded space. Past the bound
    the least recently used entry must be dropped, not kept forever."""
    searches: list[str] = []

    def respond(request: httpx.Request) -> httpx.Response:
        searches.append(json.loads(request.content)["query"])
        return httpx.Response(200, json={"foods": []})

    usda = client(respond)

    for index in range(513):
        usda.candidates(f"ingredient {index}")
    assert len(searches) == 513

    # The newest entry sits inside the default bound of 512 and stays cached.
    usda.candidates("ingredient 512")
    assert searches.count("ingredient 512") == 1

    # The oldest fell past the bound, so asking again must refetch.
    usda.candidates("ingredient 0")
    assert searches.count("ingredient 0") == 2, (
        "the oldest entry must have been evicted, forcing a refetch"
    )


def test_a_cache_hit_refreshes_recency_before_eviction() -> None:
    searches: list[str] = []

    def respond(request: httpx.Request) -> httpx.Response:
        searches.append(json.loads(request.content)["query"])
        return httpx.Response(200, json={"foods": []})

    usda = client(respond, maximum_cache_entries=2)

    usda.candidates("alpha")
    usda.candidates("beta")
    # At the bound: both entries are still served from cache.
    usda.candidates("alpha")
    usda.candidates("beta")
    assert searches == ["alpha", "beta"]

    # alpha was touched last, so inserting gamma must evict beta, not alpha.
    usda.candidates("alpha")
    usda.candidates("gamma")
    usda.candidates("alpha")
    usda.candidates("beta")

    assert searches == ["alpha", "beta", "gamma", "beta"]


def test_a_nonpositive_cache_bound_is_rejected() -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request should be made")

    with pytest.raises(ValueError, match="cache entries"):
        client(respond, maximum_cache_entries=0)
