from decimal import Decimal
from pathlib import Path

import pytest

from ladle.contracts.recipes import (
    FieldUncertaintyDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.evaluation.extraction import (
    EvaluationCorpus,
    score_nutrition_case,
    whole_recipe_prediction,
)
from ladle.nutrition.creator import apply_creator_facts
from ladle.recipes.template_clone import RecipeTemplate, TemplateNutrition

FIXTURES = Path(__file__).parents[2] / "fixtures" / "evaluation"


def template(
    *,
    servings: str = "1",
    nutrition: TemplateNutrition | None = None,
) -> RecipeTemplate:
    return RecipeTemplate(
        title="Evidence-bound recipe",
        description="",
        source=RecipeSource.YOUTUBE,
        original_url="https://www.youtube.com/watch?v=creator-facts",
        servings=servings,
        servings_basis="unknown",
        ingredients=[],
        steps=[],
        nutrition=nutrition,
        review_status=RecipeReviewStatus.NEEDS_REVIEW,
        uncertainties=[
            FieldUncertaintyDTO(field="servings", reason="Yield was absent."),
            FieldUncertaintyDTO(field="nutrition", reason="Macros were absent."),
        ],
    )


def assert_primary_nutrition(
    value: RecipeTemplate,
    *,
    calories: str,
    protein: str,
    carbohydrate: str,
    fat: str,
    serving_basis: str,
) -> None:
    assert value.nutrition is not None
    assert value.nutrition.calories == Decimal(calories)
    assert value.nutrition.protein_grams == Decimal(protein)
    assert value.nutrition.carbohydrate_grams == Decimal(carbohydrate)
    assert value.nutrition.fat_grams == Decimal(fat)
    assert value.nutrition.serving_basis == Decimal(serving_basis)
    assert value.nutrition.basis == "creatorStated"
    assert not value.nutrition.is_estimated


def test_applies_usda_per_serving_panel_and_explicit_yield() -> None:
    evidence = """
    Makes: 6 servings
    Nutrients Per Servings: Calories 259, Protein 13 g,
    Carbohydrates 51 g, Dietary Fiber 2 g, Total Fat 3 g,
    Saturated Fat 1 g.
    """

    result = apply_creator_facts(template(), [evidence])

    assert result.servings == 6
    assert result.servings_basis == "stated"
    assert_primary_nutrition(
        result,
        calories="259",
        protein="13",
        carbohydrate="51",
        fat="3",
        serving_basis="1",
    )
    assert result.nutrition is not None
    assert result.nutrition.evidence in evidence
    assert result.uncertainties == []
    assert result.review_status == RecipeReviewStatus.READY


def test_applies_interleaved_nhlbi_panel() -> None:
    evidence = """
    yield:                                 each serving provides:
    4 servings                             calories          215        total fiber 2g
                                           total fat         9g         protein 25 g
    serving size:                          saturated fat     3g         carbohydrates 9g
    """

    result = apply_creator_facts(template(), [evidence])

    assert result.servings == 4
    assert result.servings_basis == "stated"
    assert_primary_nutrition(
        result,
        calories="215",
        protein="25",
        carbohydrate="9",
        fat="9",
        serving_basis="1",
    )


def test_applies_whole_recipe_panel_only_with_stated_yield() -> None:
    evidence = """
    Yields 4 servings.
    Nutrition for entire recipe: 2,000 calories, 80 g protein,
    240 g carbs, and 60 g fat.
    """

    result = apply_creator_facts(template(), [evidence])

    assert_primary_nutrition(
        result,
        calories="2000",
        protein="80",
        carbohydrate="240",
        fat="60",
        serving_basis="4",
    )


@pytest.mark.parametrize(
    "evidence",
    [
        "Makes 4 servings. Per serving: 300 calories and 12 g protein.",
        "Calories 300, protein 12 g, carbs 20 g, fat 8 g.",
        (
            "Nutrition for whole batch: 1200 calories, 48 g protein, "
            "80 g carbs, 32 g fat."
        ),
    ],
)
def test_ignores_partial_unlabeled_or_whole_panel_without_yield(
    evidence: str,
) -> None:
    result = apply_creator_facts(template(), [evidence])

    assert result.nutrition is None


def test_conflicting_yields_or_complete_panels_do_not_override() -> None:
    existing = TemplateNutrition(
        calories="400",
        protein_grams="20",
        carbohydrate_grams="30",
        fat_grams="10",
        serving_basis="1",
        is_estimated=False,
        basis="creatorStated",
        evidence="original panel",
    )
    evidence = [
        "Makes 4 servings. Nutrients per serving: calories 300, "
        "protein 10 g, carbohydrates 20 g, total fat 8 g.",
        "Serves 6. Nutrients per serving: calories 350, "
        "protein 12 g, carbohydrates 22 g, total fat 9 g.",
    ]

    result = apply_creator_facts(template(nutrition=existing), evidence)

    assert result.servings == 1
    assert result.servings_basis == "unknown"
    assert result.nutrition == existing


def test_saturated_fat_is_not_mistaken_for_total_fat() -> None:
    evidence = """
    Makes 4 servings.
    Each serving provides: 200 calories, 10 g protein,
    25 g carbohydrates, and 3 g saturated fat.
    """

    result = apply_creator_facts(template(), [evidence])

    assert result.nutrition is None


def test_explicit_panel_corrects_model_copied_basis_and_values() -> None:
    copied = TemplateNutrition(
        calories="160",
        protein_grams="1",
        carbohydrate_grams="35",
        fat_grams="2",
        serving_basis="6",
        is_estimated=False,
        basis="creatorStated",
        evidence="model copy",
    )
    evidence = """
    Makes: 6 servings
    Nutrients Per Serving: Calories 160, Protein 1 g,
    Carbohydrates 35 g, Total Fat 2 g.
    """

    result = apply_creator_facts(template(nutrition=copied), [evidence])

    assert_primary_nutrition(
        result,
        calories="160",
        protein="1",
        carbohydrate="35",
        fat="2",
        serving_basis="1",
    )


def test_applies_unique_labeled_times_including_stacked_layout() -> None:
    evidence = """
    Prep time:
    Cook time:
    1 hour 5 minutes
    20 minutes
    Simmer the sauce for 10 minutes.
    Total time: 1 hour 25 minutes
    """

    result = apply_creator_facts(template(), [evidence])

    assert result.preparation_minutes == 65
    assert result.cooking_minutes == 20
    assert result.total_minutes == 85


def test_arbitrary_method_duration_does_not_set_top_level_time() -> None:
    result = apply_creator_facts(
        template(),
        ["Makes 2 servings. Simmer for 10 minutes, then rest for 5 minutes."],
    )

    assert result.preparation_minutes is None
    assert result.cooking_minutes is None
    assert result.total_minutes is None


@pytest.mark.parametrize(
    "fixture",
    ["text-only-tuning.json", "text-only-held-out.json"],
)
def test_all_frozen_creator_panels_reproduce_whole_recipe_reference(
    fixture: str,
) -> None:
    corpus = EvaluationCorpus.model_validate_json((FIXTURES / fixture).read_text())
    failures: dict[str, list[str]] = {}

    for case in corpus.cases:
        if case.expected_nutrition_basis != "creatorStated":
            continue
        result = apply_creator_facts(
            template(),
            [
                case.evidence.title,
                case.evidence.description,
                case.evidence.linked_document_text,
            ],
        )
        score = score_nutrition_case(
            case.nutrition,
            whole_recipe_prediction(result),
            expected_basis=case.expected_nutrition_basis,
        )
        if not score.passes:
            failures[case.id] = score.failed_fields

    assert failures == {}
