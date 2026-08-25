from decimal import Decimal
from uuid import uuid4

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
)
from ladle.contracts.recipes import RecipeReviewStatus
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedNutrition,
    ExtractedStep,
    RecipeExtraction,
)
from ladle.extraction.review import build_reviewed_template


def context(*, diagnostics: list[str] | None = None) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="review-test",
            canonical_url="https://www.tiktok.com/@cook/video/1234567890",
            source_revision="1",
        ),
        is_public=True,
        title="Recipe",
        description="",
        transcript=[],
        visual_observations=[],
        diagnostics=diagnostics or [],
    )


def test_nonblocking_defaults_and_short_recipe_caveats_stay_inline() -> None:
    extraction = RecipeExtraction(
        title="Lemon Orzo",
        description="",
        creator_name="Cook",
        servings=None,
        preparation_minutes=None,
        cooking_minutes=10,
        total_minutes=10,
        ingredients=[
            ExtractedIngredient(
                name="orzo",
                quantity_text="2 cups",
                normalized_quantity=Decimal("2"),
                unit="cup",
                preparation=None,
                confidence=0.95,
            ),
            ExtractedIngredient(
                name="lemon",
                quantity_text=None,
                normalized_quantity=None,
                unit=None,
                preparation="juiced",
                confidence=0.9,
            ),
            ExtractedIngredient(
                name="spinach",
                quantity_text=None,
                normalized_quantity=None,
                unit=None,
                preparation=None,
                confidence=0.9,
            ),
        ],
        steps=[
            ExtractedStep(
                instruction="Cook the orzo.",
                ingredient_indices=[0, 99],
                timers=[],
                confidence=0.6,
            )
        ],
        nutrition=ExtractedNutrition(
            calories=Decimal("500"),
            protein_grams=Decimal("15"),
            serving_basis=None,
            basis="unknown",
            evidence=None,
        ),
        uncertainties=[],
    )

    reviewed = build_reviewed_template(
        extraction,
        context=context(diagnostics=["visualAnalysisUnavailable"]),
    )

    assert reviewed.review_status == RecipeReviewStatus.READY
    assert reviewed.servings == 1
    assert reviewed.servings_basis == "unknown"
    assert reviewed.steps[0].ingredient_indexes == [0]
    assert reviewed.steps[0].uncertainty is not None
    assert reviewed.nutrition is None
    reasons = {value.field for value in reviewed.uncertainties}
    assert "servings" in reasons
    assert "ingredientQuantities" not in reasons
    assert "visualEvidence" in reasons


def test_confident_complete_extraction_is_ready() -> None:
    extraction = RecipeExtraction(
        title="Toast",
        description="",
        creator_name=None,
        servings=Decimal("1"),
        ingredients=[
            ExtractedIngredient(
                name="bread",
                quantity_text="1 slice",
                normalized_quantity=Decimal("1"),
                unit="slice",
                confidence=0.95,
            )
        ],
        steps=[
            ExtractedStep(
                instruction="Toast the bread.",
                ingredient_indices=[0],
                confidence=0.95,
            )
        ],
        uncertainties=[],
    )

    reviewed = build_reviewed_template(extraction, context=context())

    assert reviewed.review_status == RecipeReviewStatus.READY
    assert reviewed.servings_basis == "unknown"


def _solid_recipe(**overrides: object) -> RecipeExtraction:
    """A recipe with nothing actually wrong with it."""

    defaults: dict[str, object] = {
        "title": "Chickpea Stew",
        "description": "",
        "creator_name": "Cook",
        "servings": Decimal("4"),
        "servings_basis": "stated",
        "method_provenance": "explicit",
        "ingredients": [
            ExtractedIngredient(
                name="chickpeas",
                quantity_text="2 cans",
                normalized_quantity=Decimal("2"),
                unit="can",
                metric_amount=Decimal("800"),
                metric_unit="g",
                preparation="drained",
                confidence=0.95,
            ),
            ExtractedIngredient(
                name="cream",
                quantity_text="1 cup",
                normalized_quantity=Decimal("1"),
                unit="cup",
                metric_amount=Decimal("240"),
                metric_unit="ml",
                confidence=0.95,
            ),
        ],
        "steps": [
            ExtractedStep(
                instruction="Simmer the chickpeas in the cream until thick.",
                ingredient_indices=[0, 1],
                confidence=0.95,
            )
        ],
        "uncertainties": [],
    }
    defaults.update(overrides)
    return RecipeExtraction.model_validate(defaults)


def test_creator_stated_nutrition_is_preserved_as_non_estimated() -> None:
    nutrition = ExtractedNutrition(
        calories=Decimal("420"),
        protein_grams=Decimal("18"),
        carbohydrate_grams=Decimal("52"),
        fat_grams=Decimal("16"),
        serving_basis=Decimal("4"),
        basis="creatorStated",
        evidence="Per serving: 420 calories, 18g protein, 52g carbs, 16g fat.",
    )

    reviewed = build_reviewed_template(
        _solid_recipe(nutrition=nutrition),
        context=context(),
    )

    assert reviewed.nutrition is not None
    assert reviewed.nutrition.basis == "creatorStated"
    assert reviewed.nutrition.evidence == nutrition.evidence
    assert not reviewed.nutrition.is_estimated


def test_unknown_or_usda_claimed_model_nutrition_is_discarded() -> None:
    for basis in ("unknown", "usdaCalculated"):
        nutrition = ExtractedNutrition(
            calories=Decimal("420"),
            protein_grams=Decimal("18"),
            carbohydrate_grams=Decimal("52"),
            fat_grams=Decimal("16"),
            serving_basis=Decimal("4"),
            basis=basis,
            evidence="A model-generated estimate.",
        )

        reviewed = build_reviewed_template(
            _solid_recipe(nutrition=nutrition),
            context=context(),
        )

        assert reviewed.nutrition is None


def test_absent_creator_nutrition_remains_absent() -> None:
    reviewed = build_reviewed_template(_solid_recipe(), context=context())

    assert reviewed.nutrition is None


def test_review_retains_usda_ready_ingredient_fields() -> None:
    reviewed = build_reviewed_template(_solid_recipe(), context=context())

    chickpeas = reviewed.ingredients[0]
    assert chickpeas.metric_amount == Decimal("800")
    assert chickpeas.metric_unit == "g"
    assert chickpeas.usda_search_term == "chickpeas drained"


def test_a_legacy_unavailable_provider_code_is_not_recipe_doubt() -> None:
    """An old provider diagnostic says nothing about whether the dish is right.

    Cached acquisition contexts may retain this code, so review remains
    backward-compatible even though production no longer has a visual path.
    """

    reviewed = build_reviewed_template(
        _solid_recipe(),
        context=context(diagnostics=["visualAnalysisUnavailable"]),
    )

    assert reviewed.review_status == RecipeReviewStatus.READY
    # Still told to the cook, just not treated as a defect.
    assert "visualEvidence" in {value.field for value in reviewed.uncertainties}


def test_a_labelled_serving_estimate_does_not_force_review() -> None:
    reviewed = build_reviewed_template(
        _solid_recipe(servings_basis="estimatedFromYield"),
        context=context(),
    )

    assert reviewed.review_status == RecipeReviewStatus.READY
    assert reviewed.servings_basis == "estimatedFromYield"
    assert "servings" in {value.field for value in reviewed.uncertainties}


def test_one_shaky_garnish_does_not_condemn_the_whole_recipe() -> None:
    recipe = _solid_recipe()
    recipe.ingredients.append(
        ExtractedIngredient(
            name="parsley",
            quantity_text=None,
            is_to_taste=True,
            confidence=0.4,
            uncertainty_reason="Hard to tell how much parsley went on top.",
        )
    )

    reviewed = build_reviewed_template(recipe, context=context())

    assert reviewed.review_status == RecipeReviewStatus.READY
    assert reviewed.ingredients[-1].uncertainty is not None
    assert reviewed.ingredients[-1].is_to_taste


def test_a_reconstructed_method_still_forces_review() -> None:
    """We wrote these steps, not the creator. The cook has to be told."""

    reviewed = build_reviewed_template(
        _solid_recipe(method_provenance="inferred"),
        context=context(),
    )

    assert reviewed.review_status == RecipeReviewStatus.NEEDS_REVIEW


def test_mostly_unmeasured_ingredients_still_force_review() -> None:
    recipe = _solid_recipe()
    recipe.ingredients = [
        ExtractedIngredient(name=name, quantity_text=None, confidence=0.9)
        for name in ("chickpeas", "cream", "garlic")
    ]

    reviewed = build_reviewed_template(recipe, context=context())

    assert reviewed.review_status == RecipeReviewStatus.NEEDS_REVIEW


def test_one_missing_quantity_in_a_short_recipe_does_not_force_review() -> None:
    recipe = _solid_recipe()
    recipe.ingredients.append(
        ExtractedIngredient(name="garlic", quantity_text=None, confidence=0.9)
    )

    reviewed = build_reviewed_template(recipe, context=context())

    assert reviewed.review_status == RecipeReviewStatus.READY
    assert "ingredientQuantities" not in {
        value.field for value in reviewed.uncertainties
    }
