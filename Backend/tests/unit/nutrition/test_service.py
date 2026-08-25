from decimal import Decimal
from uuid import uuid4

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
)
from ladle.contracts.recipes import (
    FieldUncertaintyDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.nutrition.calculator import NutritionCalculator
from ladle.nutrition.normalization import (
    NormalizedRecipe,
    NutritionNormalizationUnavailable,
)
from ladle.nutrition.service import RecipeNutritionService
from ladle.nutrition.usda import FoodNutrients
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
)


class Foods:
    def candidates(self, query: str) -> list[FoodNutrients]:
        if query != "egg noodles dry":
            return []
        return [
            FoodNutrients.model_validate(
                {
                    "fdc_id": 123,
                    "description": "egg noodles dry",
                    "data_type": "Foundation",
                    "calories_per_100g": "350",
                    "protein_grams_per_100g": "14",
                    "carbohydrate_grams_per_100g": "70",
                    "fat_grams_per_100g": "1.5",
                    "portions": [],
                }
            )
        ]


class NoFoods:
    def candidates(self, _query: str) -> list[FoodNutrients]:
        return []


class Normalizer:
    def __init__(self, *, failure: Exception | None = None) -> None:
        self.failure = failure
        self.calls = 0

    def normalize(
        self,
        template: RecipeTemplate,
        **_kwargs: object,
    ) -> NormalizedRecipe:
        self.calls += 1
        if self.failure is not None:
            raise self.failure
        ingredient = template.ingredients[0].model_copy(
            update={
                "metric_amount": Decimal("400"),
                "metric_unit": "g",
                "usda_search_term": "egg noodles dry",
            }
        )
        return NormalizedRecipe(
            template=template.model_copy(
                update={
                    "servings": Decimal(4),
                    "servings_basis": "estimatedFromYield",
                    "ingredients": [ingredient],
                }
            ),
            servings_confidence=Decimal("0.85"),
            servings_rationale="Four main-dish portions from 400 g noodles.",
            assumptions=("Dry noodle mass is 400 g.",),
        )


def context() -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="7612708181004799263",
            canonical_url=("https://www.tiktok.com/@cook/video/7612708181004799263"),
            source_revision="1",
        ),
        is_public=True,
        description="Garlic noodles.",
    )


def template(
    *,
    nutrition: TemplateNutrition | None = None,
    query: str | None = None,
) -> RecipeTemplate:
    return RecipeTemplate(
        title="Garlic Noodles",
        description="",
        source=RecipeSource.TIKTOK,
        original_url="https://www.tiktok.com/@cook/video/7612708181004799263",
        servings=Decimal(1),
        servings_basis="estimatedFromYield",
        ingredients=[
            TemplateIngredient(
                name="noodles",
                metric_amount=Decimal("400") if query else None,
                metric_unit="g" if query else None,
                usda_search_term=query,
                order_index=0,
            )
        ],
        steps=[],
        nutrition=nutrition,
        review_status=RecipeReviewStatus.READY,
        uncertainties=[
            FieldUncertaintyDTO(
                field="nutrition",
                reason="stale nutrition blocker",
            )
        ],
    )


def test_creator_panel_wins_without_normalization_or_usda() -> None:
    creator = TemplateNutrition(
        calories=Decimal("500"),
        protein_grams=Decimal("20"),
        carbohydrate_grams=Decimal("60"),
        fat_grams=Decimal("20"),
        serving_basis=Decimal("1"),
        is_estimated=False,
        basis="creatorStated",
        evidence="Creator nutrition panel.",
    )
    normalizer = Normalizer()
    service = RecipeNutritionService(
        normalizer=normalizer,
        calculator=NutritionCalculator(Foods()),
    )

    result = service.enrich(
        template(nutrition=creator),
        context=context(),
        job_id=uuid4(),
    )

    assert result.nutrition is creator
    assert normalizer.calls == 0
    assert result.review_status == RecipeReviewStatus.READY
    assert not any(item.field == "nutrition" for item in result.uncertainties)


def test_success_combines_gemini_normalization_with_usda_evidence() -> None:
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(Foods()),
    )

    result = service.enrich(template(), context=context(), job_id=uuid4())

    assert result.nutrition is not None
    assert result.nutrition.calories == Decimal("350.0")
    assert result.nutrition.protein_grams == Decimal("14.0")
    assert result.nutrition.basis == "usdaCalculated"
    assert result.nutrition.is_estimated
    assert "USDA FDC 123" in (result.nutrition.evidence or "")
    assert "85%" in (result.nutrition.evidence or "")
    assert "Dry noodle mass is 400 g." in (result.nutrition.evidence or "")
    assert result.review_status == RecipeReviewStatus.READY
    assert not any(item.field == "nutrition" for item in result.uncertainties)


def test_normalization_failure_becomes_a_visible_inline_uncertainty() -> None:
    service = RecipeNutritionService(
        normalizer=Normalizer(
            failure=NutritionNormalizationUnavailable("invalid structured output")
        ),
        calculator=NutritionCalculator(Foods()),
    )

    result = service.enrich(template(), context=context(), job_id=uuid4())

    assert result.nutrition is None
    assert result.review_status == RecipeReviewStatus.READY
    blocker = next(item for item in result.uncertainties if item.field == "nutrition")
    assert "normalizationUnavailable" in blocker.reason


def test_usda_failure_names_the_unavailable_ingredient() -> None:
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(NoFoods()),
    )

    result = service.enrich(template(), context=context(), job_id=uuid4())

    assert result.nutrition is None
    assert result.review_status == RecipeReviewStatus.READY
    blocker = next(item for item in result.uncertainties if item.field == "nutrition")
    assert "foodNotFound" in blocker.reason
    assert "ingredient 0" in blocker.reason
    assert "noodles" in blocker.reason
