from decimal import Decimal
from pathlib import Path

import pytest

from ladle.evaluation.extraction import (
    EvaluationCorpus,
    IngredientNameQuantity,
    NutritionPrediction,
    NutritionReference,
    StructuralPrediction,
    StructuralReference,
    measure_structure,
    score_nutrition_case,
    summarize_nutrition_cases,
)

FIXTURES = Path(__file__).parents[2] / "fixtures" / "evaluation"


def _reference(**changes: Decimal) -> NutritionReference:
    values = {
        "servings": Decimal("4"),
        "calories": Decimal("800"),
        "protein_grams": Decimal("40"),
        "carbohydrate_grams": Decimal("80"),
        "fat_grams": Decimal("30"),
    }
    values.update(changes)
    return NutritionReference(**values)


def _prediction(
    *,
    basis: str = "usdaCalculated",
    **changes: Decimal,
) -> NutritionPrediction:
    values = _reference().model_dump()
    values.update(changes)
    return NutritionPrediction(**values, basis=basis)


def test_missing_nutrition_fails() -> None:
    score = score_nutrition_case(_reference(), None)

    assert not score.passes
    assert score.failed_fields == ["nutrition"]


def test_incorrect_serving_count_fails() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(servings=Decimal("5")),
    )

    assert not score.passes
    assert score.failed_fields == ["servings"]


def test_calories_outside_ten_percent_fail() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(calories=Decimal("881")),
    )

    assert not score.passes
    assert score.failed_fields == ["calories"]


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("protein_grams", Decimal("44.1")),
        ("carbohydrate_grams", Decimal("88.1")),
        ("fat_grams", Decimal("33.1")),
    ],
)
def test_each_macro_outside_larger_of_two_grams_or_ten_percent_fails(
    field: str,
    value: Decimal,
) -> None:
    score = score_nutrition_case(_reference(), _prediction(**{field: value}))

    assert not score.passes
    assert score.failed_fields == [field]


def test_small_macro_uses_two_gram_absolute_tolerance() -> None:
    reference = _reference(protein_grams=Decimal("5"))

    inside = score_nutrition_case(
        reference,
        _prediction(protein_grams=Decimal("7")),
    )
    outside = score_nutrition_case(
        reference,
        _prediction(protein_grams=Decimal("7.1")),
    )

    assert inside.passes
    assert outside.failed_fields == ["protein_grams"]


def test_all_nutrition_fields_must_pass_together() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(
            calories=Decimal("900"),
            protein_grams=Decimal("50"),
        ),
    )

    assert not score.passes
    assert score.failed_fields == ["calories", "protein_grams"]


def test_unknown_basis_fails_even_when_numbers_match() -> None:
    score = score_nutrition_case(_reference(), _prediction(basis="unknown"))

    assert not score.passes
    assert score.failed_fields == ["basis"]


def test_nutrition_suite_gate_requires_at_least_ninety_five_percent() -> None:
    passing = score_nutrition_case(_reference(), _prediction())
    failing = score_nutrition_case(_reference(), None)

    below_gate = summarize_nutrition_cases([passing] * 18 + [failing, failing])
    at_gate = summarize_nutrition_cases([passing] * 19 + [failing])

    assert below_gate.pass_rate == Decimal("0.9")
    assert not below_gate.meets_gate
    assert at_gate.pass_rate == Decimal("0.95")
    assert at_gate.meets_gate


def test_structural_measurements_are_reported_separately() -> None:
    reference = StructuralReference(
        stated_cook_time_minutes=Decimal("30"),
        ingredient_name_quantities=[
            IngredientNameQuantity(name="olive oil", quantity="2 tbsp"),
            IngredientNameQuantity(name="chickpeas", quantity="1 can"),
        ],
        ordered_step_phrases=["heat the oil", "add the chickpeas", "simmer"],
    )
    prediction = StructuralPrediction(
        stated_cook_time_minutes=Decimal("25"),
        ingredient_name_quantities=[
            IngredientNameQuantity(name="Olive Oil", quantity="2 TBSP"),
        ],
        steps=["Heat the oil.", "Simmer until thick."],
    )

    measured = measure_structure(reference, prediction)

    assert not measured.cook_time_matches
    assert measured.ingredient_pairs_matched == 1
    assert measured.ingredient_pairs_total == 2
    assert measured.ordered_step_phrases_matched == 2
    assert measured.ordered_step_phrases_total == 3


@pytest.mark.parametrize(
    ("filename", "partition"),
    [
        ("text-only-tuning.json", "tuning"),
        ("text-only-held-out.json", "heldOut"),
    ],
)
def test_checked_in_reference_fixtures_are_schema_valid(
    filename: str,
    partition: str,
) -> None:
    corpus = EvaluationCorpus.model_validate_json((FIXTURES / filename).read_text())

    assert corpus.partition == partition
    assert corpus.reference_status == "scaffold"
    assert corpus.cases
