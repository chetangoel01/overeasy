import json
from copy import deepcopy
from pathlib import Path
from typing import Any
from uuid import uuid4

import pytest
from pydantic import ValidationError

from ladle.contracts.recipes import RecipeDTO

FIXTURE = Path(__file__).parents[3] / "Contracts" / "Fixtures" / "recipe-ready.json"


def recipe_payload() -> dict[str, Any]:
    return json.loads(FIXTURE.read_text())


def set_path(
    value: dict[str, Any], path: tuple[str | int, ...], replacement: Any
) -> None:
    current: Any = value
    for part in path[:-1]:
        current = current[part]
    current[path[-1]] = replacement


@pytest.mark.parametrize(
    ("path", "maximum"),
    [
        (("title",), 300),
        (("description",), 10_000),
        (("creatorName",), 200),
        (("ingredients", 0, "preparation"), 500),
        (("steps", 0, "instruction"), 5_000),
        (("steps", 0, "timers", 0, "label"), 200),
    ],
)
def test_recipe_text_fields_have_explicit_maxima(
    path: tuple[str | int, ...],
    maximum: int,
) -> None:
    payload = recipe_payload()
    set_path(payload, path, "x" * (maximum + 1))

    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


@pytest.mark.parametrize(
    ("field", "maximum", "template"),
    [
        ("images", 20, {"id": str(uuid4()), "remoteURL": "https://example.com/a"}),
        (
            "ingredients",
            200,
            {
                "id": str(uuid4()),
                "name": "salt",
                "orderIndex": 0,
            },
        ),
        (
            "steps",
            200,
            {
                "id": str(uuid4()),
                "instruction": "Stir.",
                "orderIndex": 0,
            },
        ),
        ("notes", 100, "Remember this."),
        (
            "uncertainties",
            200,
            {"field": "title", "reason": "The source was unclear."},
        ),
    ],
)
def test_recipe_top_level_collections_have_explicit_maxima(
    field: str,
    maximum: int,
    template: object,
) -> None:
    payload = recipe_payload()
    payload[field] = [deepcopy(template) for _ in range(maximum + 1)]

    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


def test_nested_recipe_collections_have_explicit_maxima() -> None:
    payload = recipe_payload()
    payload["steps"][0]["ingredientIDs"] = [payload["ingredients"][0]["id"]] * 201
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)

    payload = recipe_payload()
    payload["steps"][0]["timers"] = [
        deepcopy(payload["steps"][0]["timers"][0]) for _ in range(21)
    ]
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)

    payload = recipe_payload()
    assert payload["nutrition"] is not None
    nutrient = payload["nutrition"]["otherNutrients"][0]
    payload["nutrition"]["otherNutrients"] = [deepcopy(nutrient) for _ in range(101)]
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


def test_uncertainty_and_note_text_are_bounded() -> None:
    payload = recipe_payload()
    payload["notes"] = ["x" * 2_001]
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)

    payload = recipe_payload()
    payload["uncertainties"] = [{"field": "x" * 256, "reason": "x" * 1_001}]
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("servings",), "NaN"),
        (("servings",), "-1"),
        (("servings",), "10001"),
        (("ingredients", 0, "normalizedQuantity"), "1000001"),
        (("nutrition", "calories"), "Infinity"),
        (("nutrition", "calories"), "-1"),
        (("nutrition", "otherNutrients", 0, "amount"), "1000001"),
        (("nutrition", "servingBasis"), "0"),
    ],
)
def test_recipe_decimals_are_finite_nonnegative_and_bounded(
    path: tuple[str | int, ...],
    value: str,
) -> None:
    payload = recipe_payload()
    set_path(payload, path, value)

    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


@pytest.mark.parametrize(
    ("path", "value"),
    [
        (("preparationMinutes",), 43_201),
        (("cookingMinutes",), 43_201),
        (("totalMinutes",), 43_201),
        (("steps", 0, "timers", 0, "durationSeconds"), 2_592_001),
        (("steps", 0, "sourceStartSeconds"), float("inf")),
        (("steps", 0, "sourceEndSeconds"), 86_401),
    ],
)
def test_recipe_durations_are_finite_nonnegative_and_bounded(
    path: tuple[str | int, ...],
    value: int | float,
) -> None:
    payload = recipe_payload()
    set_path(payload, path, value)

    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(payload)


def test_recipe_rejects_unknown_and_duplicate_ingredient_references() -> None:
    payload = recipe_payload()
    payload["steps"][0]["ingredientIDs"] = [str(uuid4())]
    with pytest.raises(ValidationError, match="unknown ingredient"):
        RecipeDTO.model_validate(payload)

    payload = recipe_payload()
    ingredient_id = payload["ingredients"][0]["id"]
    payload["steps"][0]["ingredientIDs"] = [ingredient_id, ingredient_id]
    with pytest.raises(ValidationError, match="unique"):
        RecipeDTO.model_validate(payload)


def test_recipe_has_total_collection_complexity_budget() -> None:
    payload = recipe_payload()
    ingredient = payload["ingredients"][0]
    payload["ingredients"] = []
    for index in range(200):
        value = deepcopy(ingredient)
        value["id"] = str(uuid4())
        value["orderIndex"] = index
        payload["ingredients"].append(value)
    ingredient_ids = [value["id"] for value in payload["ingredients"]]

    step = payload["steps"][0]
    payload["steps"] = []
    for index in range(26):
        value = deepcopy(step)
        value["id"] = str(uuid4())
        value["orderIndex"] = index
        value["ingredientIDs"] = ingredient_ids
        value["timers"] = []
        payload["steps"].append(value)

    with pytest.raises(ValidationError, match="collection complexity"):
        RecipeDTO.model_validate(payload)


def test_recipe_has_decoded_node_and_nesting_budgets() -> None:
    payload = recipe_payload()
    payload["unknown"] = [0] * 10_001
    with pytest.raises(ValidationError, match="decoded object complexity"):
        RecipeDTO.model_validate(payload)

    payload = recipe_payload()
    nested: object = "leaf"
    for _ in range(9):
        nested = [nested]
    payload["unknown"] = nested
    with pytest.raises(ValidationError, match="nesting"):
        RecipeDTO.model_validate(payload)
