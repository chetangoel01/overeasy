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


def test_defaults_and_coverage_problems_become_needs_review() -> None:
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
        ),
        uncertainties=[],
    )

    reviewed = build_reviewed_template(
        extraction,
        context=context(diagnostics=["visualAnalysisUnavailable"]),
    )

    assert reviewed.review_status == RecipeReviewStatus.NEEDS_REVIEW
    assert reviewed.servings == 1
    assert reviewed.steps[0].ingredient_indexes == [0]
    assert reviewed.steps[0].uncertainty is not None
    assert reviewed.nutrition is not None
    assert reviewed.nutrition.serving_basis == 1
    assert reviewed.nutrition.is_estimated
    reasons = {value.field for value in reviewed.uncertainties}
    assert "servings" in reasons
    assert "ingredientQuantities" in reasons
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


def test_nutrition_without_a_basis_remains_per_serving() -> None:
    extraction = _solid_recipe(
        servings=Decimal("11"),
        nutrition=ExtractedNutrition(
            calories=Decimal("625"),
            protein_grams=Decimal("55"),
            serving_basis=None,
        ),
    )

    reviewed = build_reviewed_template(extraction, context=context())

    assert reviewed.nutrition is not None
    assert reviewed.nutrition.calories == Decimal("625")
    assert reviewed.nutrition.protein_grams == Decimal("55")
    assert reviewed.nutrition.serving_basis == Decimal("1")


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


def test_an_unavailable_provider_is_not_a_doubt_about_the_recipe() -> None:
    """Visual analysis being down says nothing about whether this dish is right.

    It used to force review anyway, and because the visual provider is often
    unavailable that pushed essentially every import into the review queue.
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
