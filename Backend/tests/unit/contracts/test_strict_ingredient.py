"""An ingredient is a quantity, a unit and a name — or it has no quantity.

Every row a cook reads is rendered from `normalizedQuantity`, `unit` and
`name`. `quantityText` is the creator's phrase, kept as a note that no row
prints, so a split left empty by the model would render as a bare name and
silently lose the amount. `IngredientDTO` is where the guarantee lands: the
API cannot emit, store or accept an ingredient that has an amount it did not
also express as a number.
"""

from decimal import Decimal
from uuid import UUID

from ladle.contracts.recipes import IngredientDTO

INGREDIENT_ID = UUID("22000000-0000-4000-8000-000000000001")


def ingredient(**fields: object) -> IngredientDTO:
    return IngredientDTO.model_validate(
        {"id": str(INGREDIENT_ID), "name": "flour", "orderIndex": 0} | fields
    )


def test_a_phrase_the_model_did_not_split_is_split_on_the_way_in() -> None:
    value = ingredient(quantityText="2 cups")

    assert value.normalized_quantity == Decimal("2")
    assert value.unit == "cups"
    assert value.is_to_taste is False
    # The phrase is kept. It is a note, not a rendering instruction.
    assert value.quantity_text == "2 cups"


def test_a_missing_number_beside_a_stated_unit_is_recovered() -> None:
    value = ingredient(quantityText="100 g", unit="g")

    assert value.normalized_quantity == Decimal("100")
    assert value.unit == "g"


def test_a_missing_unit_beside_a_stated_number_is_recovered() -> None:
    value = ingredient(quantityText="2 cups", normalizedQuantity="2")

    assert value.unit == "cups"


def test_a_phrase_that_disagrees_with_the_number_does_not_lend_its_unit() -> None:
    """The two would then describe different amounts.

    A stored number is the fact; a phrase whose own number is something else
    is not a description of it, and half of it cannot be borrowed.
    """

    value = ingredient(quantityText="3 cups", normalizedQuantity="2")

    assert value.normalized_quantity == Decimal("2")
    assert value.unit is None


def test_a_phrase_that_names_the_ingredient_lends_no_unit() -> None:
    """A phrase like "1/2 lemon" counts the ingredient, never measures it."""

    value = ingredient(name="lemon", quantityText="1/2 lemon")

    assert value.normalized_quantity == Decimal("0.5")
    assert value.unit is None


def test_a_count_keeps_its_missing_unit() -> None:
    value = ingredient(name="potato rolls", quantityText="4")

    assert value.normalized_quantity == Decimal("4")
    assert value.unit is None
    assert value.is_to_taste is False


def test_a_phrase_with_no_number_becomes_an_ingredient_with_no_quantity() -> None:
    value = ingredient(name="flaky salt", quantityText="to taste")

    assert value.is_to_taste is True
    assert value.normalized_quantity is None


def test_an_ingredient_with_nothing_said_about_its_amount_has_no_quantity() -> None:
    value = ingredient(name="olive oil")

    assert value.is_to_taste is True
    assert value.normalized_quantity is None


def test_a_flagged_ingredient_is_left_exactly_as_it_came() -> None:
    value = ingredient(name="salt", quantityText="a pinch", isToTaste=True)

    assert value.is_to_taste is True
    assert value.normalized_quantity is None
    assert value.quantity_text == "a pinch"


def test_a_split_the_model_supplied_is_never_second_guessed() -> None:
    value = ingredient(
        quantityText="2 16oz cans",
        normalizedQuantity="2",
        unit="cans",
    )

    assert value.normalized_quantity == Decimal("2")
    assert value.unit == "cans"


def test_zero_is_an_amount_and_not_an_absence() -> None:
    value = ingredient(quantityText="0 g", normalizedQuantity="0", unit="g")

    assert value.normalized_quantity == Decimal("0")
    assert value.is_to_taste is False


def test_the_flag_is_on_the_wire_under_its_camel_case_name() -> None:
    payload = ingredient(name="salt").model_dump(mode="json", by_alias=True)

    assert payload["isToTaste"] is True
    assert IngredientDTO.model_validate(payload).is_to_taste is True


def test_the_guarantee_holds_when_the_dto_is_validated_again() -> None:
    once = ingredient(quantityText="1 1/2 tsp")
    twice = IngredientDTO.model_validate(once.model_dump(mode="json", by_alias=True))

    assert twice == once
