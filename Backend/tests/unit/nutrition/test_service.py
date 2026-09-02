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
    name = "USDA FDC"

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
    name = "USDA FDC"

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
        ingredients = [
            value.model_copy(
                update={
                    "metric_amount": value.metric_amount or Decimal("400"),
                    "metric_unit": "g",
                    "usda_search_term": (value.usda_search_term or "egg noodles dry"),
                }
            )
            for value in template.ingredients
        ]
        return NormalizedRecipe(
            template=template.model_copy(
                update={
                    "servings": Decimal(4),
                    "servings_basis": "estimatedFromYield",
                    "ingredients": ingredients,
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


def uncounted_ingredient(
    *,
    name: str,
    query: str,
    grams: str,
    order_index: int,
) -> TemplateIngredient:
    return TemplateIngredient(
        name=name,
        metric_amount=Decimal(grams),
        metric_unit="g",
        usda_search_term=query,
        order_index=order_index,
    )


def template(
    *,
    nutrition: TemplateNutrition | None = None,
    query: str | None = None,
    extra: list[TemplateIngredient] | None = None,
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
            ),
            *(extra or []),
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
    """Nothing is left to total when the only ingredient goes uncounted.

    The recipe is blocked for coverage rather than for the lookup, and the
    blocker still says which ingredient could not be costed.
    """
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(NoFoods()),
    )

    result = service.enrich(template(), context=context(), job_id=uuid4())

    assert result.nutrition is None
    assert result.review_status == RecipeReviewStatus.READY
    blocker = next(item for item in result.uncertainties if item.field == "nutrition")
    assert "insufficientCoverage" in blocker.reason
    assert "noodles" in blocker.reason


def test_an_uncounted_ingredient_keeps_the_totals_and_marks_the_row() -> None:
    """The recipe keeps its calories and says what is missing from them.

    The row note is what a cook reads beside the ingredient; the recipe-level
    note is what the nutrition panel reads above the numbers.
    """
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(Foods()),
    )

    result = service.enrich(
        template(
            extra=[
                uncounted_ingredient(
                    name="garam masala",
                    query="garam masala",
                    grams="20",
                    order_index=1,
                )
            ]
        ),
        context=context(),
        job_id=uuid4(),
    )

    assert result.nutrition is not None
    assert result.nutrition.calories == Decimal("350.0")

    row = result.ingredients[1].uncertainty
    assert row is not None
    assert row.field == "ingredients[1].nutrition"
    assert row.reason == ("Not counted: no nutrition record found for garam masala.")
    assert row in result.uncertainties

    summary = next(item for item in result.uncertainties if item.field == "nutrition")
    assert summary.reason == "1 of 2 ingredients not counted: garam masala."


def test_uncounted_mass_over_the_share_blocks_and_names_the_ingredients() -> None:
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(Foods()),
    )

    result = service.enrich(
        template(
            extra=[
                uncounted_ingredient(
                    name="garam masala",
                    query="garam masala",
                    grams="200",
                    order_index=1,
                )
            ]
        ),
        context=context(),
        job_id=uuid4(),
    )

    assert result.nutrition is None
    blocker = next(item for item in result.uncertainties if item.field == "nutrition")
    assert "insufficientCoverage" in blocker.reason
    assert "garam masala" in blocker.reason
    assert not any(item.field.endswith(".nutrition") for item in result.uncertainties)


def test_last_runs_notes_do_not_survive_a_clean_recalculation() -> None:
    """Re-enrichment feeds the stored uncertainties back in.

    A recipe refreshed after a provider improves must not keep telling the
    cook an ingredient was skipped once it has been counted.
    """
    stale = FieldUncertaintyDTO(
        field="ingredients[0].nutrition",
        reason="Not counted: no nutrition record found for noodles.",
    )
    service = RecipeNutritionService(
        normalizer=Normalizer(),
        calculator=NutritionCalculator(Foods()),
    )
    value = template()
    value = value.model_copy(
        update={
            "uncertainties": [*value.uncertainties, stale],
            "ingredients": [
                value.ingredients[0].model_copy(update={"uncertainty": stale})
            ],
        }
    )

    result = service.enrich(value, context=context(), job_id=uuid4())

    assert result.nutrition is not None
    assert result.uncertainties == []
    assert result.ingredients[0].uncertainty is None
    assert result.review_status == RecipeReviewStatus.READY
