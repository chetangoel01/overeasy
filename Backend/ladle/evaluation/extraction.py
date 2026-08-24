"""Deterministic scoring for the text-only extraction benchmark."""

from decimal import Decimal
from typing import Literal

from pydantic import Field

from ladle.contracts.common import WireModel

NUTRITION_GATE = Decimal("0.95")
RELATIVE_TOLERANCE = Decimal("0.10")
MACRO_ABSOLUTE_TOLERANCE_GRAMS = Decimal("2")
NutritionBasis = Literal["creatorStated", "usdaCalculated", "unknown"]


class NutritionReference(WireModel):
    """Authoritative whole-recipe nutrition and stated serving count."""

    servings: Decimal = Field(gt=0)
    calories: Decimal = Field(ge=0)
    protein_grams: Decimal = Field(ge=0)
    carbohydrate_grams: Decimal = Field(ge=0)
    fat_grams: Decimal = Field(ge=0)


class NutritionPrediction(NutritionReference):
    """Pipeline output with the evidence basis used to produce its values."""

    basis: NutritionBasis


class NutritionCaseScore(WireModel):
    passes: bool
    failed_fields: list[str]


class NutritionSuiteSummary(WireModel):
    passed: int
    total: int
    pass_rate: Decimal
    meets_gate: bool


class IngredientNameQuantity(WireModel):
    name: str
    quantity: str


class StructuralReference(WireModel):
    stated_cook_time_minutes: Decimal | None = Field(default=None, ge=0)
    ingredient_name_quantities: list[IngredientNameQuantity]
    ordered_step_phrases: list[str]


class StructuralPrediction(WireModel):
    stated_cook_time_minutes: Decimal | None = Field(default=None, ge=0)
    ingredient_name_quantities: list[IngredientNameQuantity]
    steps: list[str]


class StructuralMeasurement(WireModel):
    cook_time_matches: bool | None
    ingredient_pairs_matched: int
    ingredient_pairs_total: int
    ordered_step_phrases_matched: int
    ordered_step_phrases_total: int


class EvaluationReferenceCase(WireModel):
    id: str = Field(min_length=1)
    cache_key: str = Field(min_length=1)
    source_url: str = Field(min_length=1)
    nutrition: NutritionReference
    structure: StructuralReference


class EvaluationCorpus(WireModel):
    corpus_name: str = Field(min_length=1)
    fixture_version: str = Field(min_length=1)
    partition: Literal["tuning", "heldOut"]
    reference_status: Literal["scaffold", "verified"]
    cases: list[EvaluationReferenceCase] = Field(min_length=1)


def _within(value: Decimal, expected: Decimal, tolerance: Decimal) -> bool:
    return abs(value - expected) <= tolerance


def score_nutrition_case(
    reference: NutritionReference,
    prediction: NutritionPrediction | None,
) -> NutritionCaseScore:
    """Score one recipe; every required nutrition field must pass together."""

    if prediction is None:
        return NutritionCaseScore(passes=False, failed_fields=["nutrition"])

    failed: list[str] = []
    if prediction.basis == "unknown":
        failed.append("basis")
    if prediction.servings != reference.servings:
        failed.append("servings")
    if not _within(
        prediction.calories,
        reference.calories,
        reference.calories * RELATIVE_TOLERANCE,
    ):
        failed.append("calories")

    for field in ("protein_grams", "carbohydrate_grams", "fat_grams"):
        expected = getattr(reference, field)
        tolerance = max(
            MACRO_ABSOLUTE_TOLERANCE_GRAMS,
            expected * RELATIVE_TOLERANCE,
        )
        if not _within(getattr(prediction, field), expected, tolerance):
            failed.append(field)

    return NutritionCaseScore(passes=not failed, failed_fields=failed)


def nutrition_case_passes(
    reference: NutritionReference,
    prediction: NutritionPrediction | None,
) -> bool:
    """Return the whole-recipe nutrition gate result for one case."""

    return score_nutrition_case(reference, prediction).passes


def summarize_nutrition_cases(
    scores: list[NutritionCaseScore],
) -> NutritionSuiteSummary:
    total = len(scores)
    passed = sum(score.passes for score in scores)
    pass_rate = Decimal(passed) / Decimal(total) if total else Decimal(0)
    return NutritionSuiteSummary(
        passed=passed,
        total=total,
        pass_rate=pass_rate,
        meets_gate=total > 0 and pass_rate >= NUTRITION_GATE,
    )


def _normalize(value: str) -> str:
    return " ".join(value.casefold().split())


def measure_structure(
    reference: StructuralReference,
    prediction: StructuralPrediction,
) -> StructuralMeasurement:
    """Measure useful structure without folding it into the nutrition gate."""

    expected_pairs = {
        (_normalize(value.name), _normalize(value.quantity))
        for value in reference.ingredient_name_quantities
    }
    predicted_pairs = {
        (_normalize(value.name), _normalize(value.quantity))
        for value in prediction.ingredient_name_quantities
    }

    instructions = _normalize(" ".join(prediction.steps))
    cursor = 0
    matched_phrases = 0
    for phrase in reference.ordered_step_phrases:
        index = instructions.find(_normalize(phrase), cursor)
        if index >= 0:
            matched_phrases += 1
            cursor = index + len(_normalize(phrase))

    expected_time = reference.stated_cook_time_minutes
    return StructuralMeasurement(
        cook_time_matches=(
            None
            if expected_time is None
            else prediction.stated_cook_time_minutes == expected_time
        ),
        ingredient_pairs_matched=len(expected_pairs & predicted_pairs),
        ingredient_pairs_total=len(expected_pairs),
        ordered_step_phrases_matched=matched_phrases,
        ordered_step_phrases_total=len(reference.ordered_step_phrases),
    )
