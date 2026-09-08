"""The split a creator's phrase gives up, and what it refuses to guess.

An ingredient is a quantity, a unit and a name. Where the model left the
first two empty and the creator's phrase holds them, this is what recovers
them; where the phrase holds no number at all, recovering nothing is the
answer, and the caller flags the row as having no quantity rather than
inventing one.
"""

from decimal import Decimal

import pytest

from ladle.contracts.quantities import split_quantity


@pytest.mark.parametrize(
    ("phrase", "quantity", "unit"),
    [
        ("2 cups", Decimal("2"), "cups"),
        ("100 g", Decimal("100"), "g"),
        # No space between the two halves is how creators write metric.
        ("100g", Decimal("100"), "g"),
        ("2 tbsp.", Decimal("2"), "tbsp."),
        # A count has no unit, and inventing one would print "2 eggs eggs".
        ("2", Decimal("2"), None),
        ("1/2", Decimal("0.5"), None),
        ("1/2 lemon", Decimal("0.5"), "lemon"),
        ("1 1/2 tsp", Decimal("1.5"), "tsp"),
        ("½ cup", Decimal("0.5"), "cup"),
        ("1½ cups", Decimal("1.5"), "cups"),
        ("0.75 lb", Decimal("0.75"), "lb"),
        # A range starts somewhere. The low end is the amount to measure,
        # and the rest of the phrase stays in quantityText as the note.
        ("2-3 cloves", Decimal("2"), None),
        # "2 16oz cans" is a count of a packaged size: the token after the
        # number is not a unit, so the row is a count of something.
        ("2 16oz cans", Decimal("2"), None),
        ("  2   cups  ", Decimal("2"), "cups"),
    ],
)
def test_a_phrase_gives_up_its_number_and_unit(
    phrase: str, quantity: Decimal, unit: str | None
) -> None:
    assert split_quantity(phrase) == (quantity, unit)


@pytest.mark.parametrize(
    "phrase",
    [
        None,
        "",
        "   ",
        "a splash",
        "to taste",
        "handful",
        # Nothing recognisable leads it, so there is no amount to take.
        "-1 cup",
    ],
)
def test_a_phrase_with_no_number_yields_nothing(phrase: str | None) -> None:
    assert split_quantity(phrase) == (None, None)


def test_an_absurd_number_is_not_an_amount() -> None:
    """Past the contract's ceiling the value cannot be stored at all.

    Returning it would have the caller assign a field its own constraints
    reject, and emit a recipe the API could not read back.
    """

    assert split_quantity("99999999 cups") == (None, None)


def test_a_long_repeating_fraction_is_rounded_to_what_the_wire_carries() -> None:
    assert split_quantity("2/3 cup") == (Decimal("0.666667"), "cup")


def test_a_unit_longer_than_the_contract_allows_is_dropped() -> None:
    quantity, unit = split_quantity(f"2 {'x' * 60}")

    assert quantity == Decimal("2")
    assert unit is None
