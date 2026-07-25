"""Recipes are written in fractions; the schema has to accept them.

A rejected field fails the whole payload, so a single "2/3 cup" used to
discard an entire extraction — every ingredient and every step — and surface
to the cook as a parser failure. These pin the notations that must survive.
"""

from decimal import Decimal

import pytest
from pydantic import ValidationError

from ladle.extraction.models import ExtractedIngredient, RecipeExtraction


def ingredient(quantity: object) -> ExtractedIngredient:
    return ExtractedIngredient.model_validate(
        {"name": "flour", "normalizedQuantity": quantity, "confidence": 0.9}
    )


@pytest.mark.parametrize(
    ("written", "expected"),
    [
        ("1/2", Decimal("0.5")),
        ("2/3", Decimal("0.666667")),
        ("1/4", Decimal("0.25")),
        ("3 / 4", Decimal("0.75")),
        ("1 1/2", Decimal("1.5")),
        ("2 3/4", Decimal("2.75")),
        ("½", Decimal("0.5")),
        ("⅔", Decimal("0.666667")),
        ("1½", Decimal("1.5")),
        # Plain decimals must keep working untouched.
        ("2", Decimal("2")),
        ("0.75", Decimal("0.75")),
    ],
)
def test_fractions_are_accepted_as_quantities(written: str, expected: Decimal) -> None:
    assert ingredient(written).normalized_quantity == expected


def test_numbers_are_left_alone() -> None:
    assert ingredient(2).normalized_quantity == Decimal(2)
    assert ingredient(None).normalized_quantity is None


@pytest.mark.parametrize("written", ["", "a lot", "1/0", "some/thing", "--"])
def test_nonsense_is_still_rejected(written: str) -> None:
    """Being liberal about notation must not mean inventing a number."""

    with pytest.raises(ValidationError):
        ingredient(written)


def test_one_fraction_no_longer_discards_the_whole_recipe() -> None:
    payload = {
        "title": "Chicken Piccata Pasta",
        "description": "",
        "servings": "1 1/2",
        "ingredients": [
            {"name": "flour", "normalizedQuantity": "2/3", "confidence": 1.0},
            {
                "name": "pasta water",
                "normalizedQuantity": "1/2",
                "metricAmount": "1/4",
                "confidence": 1.0,
            },
        ],
        "steps": [
            {"instruction": "Dredge the chicken.", "confidence": 1.0},
        ],
        "nutrition": {"calories": "1/2", "servingBasis": "1/2"},
    }

    extraction = RecipeExtraction.model_validate(payload)

    assert extraction.servings == Decimal("1.5")
    assert extraction.ingredients[0].normalized_quantity == Decimal("0.666667")
    assert extraction.ingredients[1].metric_amount == Decimal("0.25")
    assert extraction.nutrition is not None
    assert extraction.nutrition.calories == Decimal("0.5")
