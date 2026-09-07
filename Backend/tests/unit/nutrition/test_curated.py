"""The checked-in table of foods USDA has no usable record for.

Every value in it is an estimate that a human read in a diff before it
merged, so these tests are the mechanical half of that review: they check
that a row cannot be added without a complete panel, an alias, a stated
basis, and macros that agree with the calories beside them. Whether the
numbers are *right* is the reviewer's job; whether they are *coherent* is
this file's.
"""

from decimal import Decimal

import pytest

from ladle.nutrition.calculator import _consistent
from ladle.nutrition.curated import CuratedFood, CuratedFoodTable, curated_food_table


def curated(
    *,
    identifier: int = 9000001,
    name: str = "garam masala",
    aliases: list[str] | None = None,
) -> CuratedFood:
    return CuratedFood.model_validate(
        {
            "id": identifier,
            "name": name,
            "aliases": aliases if aliases is not None else ["garam masala powder"],
            "basis": "Mean of six USDA spice records.",
            "calories_per_100g": "292.7",
            "protein_grams_per_100g": "10.2",
            "carbohydrate_grams_per_100g": "63.0",
            "fat_grams_per_100g": "10.7",
            "fibre_grams_per_100g": "32.1",
            "portions": [{"amount": "1", "measure_unit": "tsp", "gram_weight": "2.5"}],
        }
    )


def test_the_shipped_table_loads() -> None:
    assert curated_food_table().entries


def test_every_entry_carries_a_complete_panel_and_a_stated_basis() -> None:
    """A row with a hole in it is worse than no row.

    The calculator asks nothing of a curated record that it asks of a USDA
    one, so a missing fibre figure would quietly become zero and push the
    consistency band the wrong way.
    """
    for entry in curated_food_table().entries:
        assert entry.basis.strip()
        assert entry.aliases
        for value in (
            entry.calories_per_100g,
            entry.protein_grams_per_100g,
            entry.carbohydrate_grams_per_100g,
            entry.fat_grams_per_100g,
            entry.fibre_grams_per_100g,
        ):
            assert value >= 0


def test_every_panel_agrees_with_its_own_macros() -> None:
    """The same Atwater check USDA records have to pass.

    An estimate that fails it is not a rounding difference; it means the
    macros and the calories were guessed independently.
    """
    for entry in curated_food_table().entries:
        assert _consistent(entry.nutrients()), entry.name


def test_every_portion_weighs_something() -> None:
    for entry in curated_food_table().entries:
        for portion in entry.portions:
            assert portion.amount > 0
            assert portion.gram_weight > 0


def test_the_known_gaps_are_the_ones_in_the_table() -> None:
    """The seed set, and nothing padding it out.

    Each of these was recorded as skipped by a dry run or a probe, and each
    was checked against USDA before it was added.
    """
    assert [entry.name for entry in curated_food_table().entries] == [
        "garam masala",
        "curry leaves",
        "ginger garlic paste",
        "tamarind paste",
        "italian seasoning",
    ]


def test_an_alias_is_matched_through_case_and_punctuation() -> None:
    table = curated_food_table()

    assert table.lookup("Ginger-Garlic Paste") is not None
    assert table.lookup("kadi patta") is not None
    assert table.lookup("Curry Leaf") is not None


def test_an_ingredient_the_table_does_not_carry_is_not_answered() -> None:
    table = curated_food_table()

    assert table.lookup("chicken thighs") is None
    assert table.lookup(None) is None
    assert table.lookup("") is None


def test_plain_tamarind_is_left_to_usda() -> None:
    """USDA has the fruit; only the paste is missing.

    A curated row that displaced `Tamarinds, raw` would replace a
    laboratory record with an estimate, which is the opposite of the point.
    """
    assert curated_food_table().lookup("tamarind") is None
    assert curated_food_table().lookup("tamarind paste") is not None


def test_no_two_entries_answer_to_the_same_name() -> None:
    with pytest.raises(ValueError, match="curry leaves"):
        CuratedFoodTable(
            [
                curated(identifier=9000001, name="curry leaves"),
                curated(
                    identifier=9000002, name="kadi patta", aliases=["Curry Leaves"]
                ),
            ]
        )


def test_an_entry_answers_to_its_own_name_as_well_as_its_aliases() -> None:
    table = CuratedFoodTable([curated()])

    assert table.lookup("garam masala") is not None
    assert table.lookup("garam masala powder") is not None


def test_a_curated_record_carries_the_table_as_its_data_type() -> None:
    """The panel is not a USDA data type and must not claim to be one."""
    record = curated().nutrients()

    assert record.data_type == "Curated"
    assert record.description == "garam masala"
    assert record.calories_per_100g == Decimal("292.7")
