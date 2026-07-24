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
