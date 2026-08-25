from decimal import Decimal
from uuid import uuid4

import pytest

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.nutrition.normalization import (
    NormalizedIngredient,
    NutritionNormalization,
    NutritionNormalizationResponse,
    NutritionNormalizationUnavailable,
    RecipeNutritionNormalizer,
)
from ladle.recipes.template_clone import RecipeTemplate, TemplateIngredient


class Client:
    def __init__(self, value: NutritionNormalization) -> None:
        self.value = value

    def normalize(self, **_kwargs: object) -> NutritionNormalizationResponse:
        return NutritionNormalizationResponse(
            parsed_output=self.value,
            input_tokens=10,
            output_tokens=20,
            cost_usd=Decimal("0.01"),
        )


def context() -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="7612708181004799263",
            canonical_url=(
                "https://www.tiktok.com/@cook/video/7612708181004799263"
            ),
            source_revision="1",
        ),
        is_public=True,
        description="14 oz noodles with sauce",
    )


def template(*, servings: str, basis: str) -> RecipeTemplate:
    return RecipeTemplate(
        title="Garlic Noodles",
        description="",
        source=RecipeSource.TIKTOK,
        original_url="https://www.tiktok.com/@cook/video/7612708181004799263",
        servings=Decimal(servings),
        servings_basis=basis,  # type: ignore[arg-type]
        ingredients=[
            TemplateIngredient(
                quantity_text="14 oz",
                normalized_quantity=Decimal(14),
                unit="oz",
                name="noodles",
                metric_amount=Decimal("396.9"),
                metric_unit="g",
                usda_search_term="noodles",
                order_index=0,
            ),
            TemplateIngredient(
                quantity_text=None,
                name="vegetable oil",
                usda_search_term="vegetable oil",
                order_index=1,
            ),
            TemplateIngredient(
                quantity_text=None,
                name="salt",
                usda_search_term="salt",
                is_to_taste=True,
                order_index=2,
            ),
        ],
        steps=[],
        review_status=RecipeReviewStatus.READY,
    )


def response(*, servings: str = "4") -> NutritionNormalization:
    return NutritionNormalization(
        servings=Decimal(servings),
        servings_confidence=Decimal("0.95"),
        servings_rationale="Four portions from fourteen ounces of noodles.",
        ingredients=[
            NormalizedIngredient(
                ingredient_index=0,
                usda_search_term="egg noodles dry",
                grams=Decimal("396.9"),
                was_inferred=False,
                rationale="Direct ounce conversion.",
            ),
            NormalizedIngredient(
                ingredient_index=1,
                usda_search_term="vegetable oil",
                grams=Decimal("13.6"),
                was_inferred=True,
                rationale="One tablespoon for sauteing.",
            ),
        ],
        excluded_ingredient_indexes=[],
        assumptions=["Vegetable oil estimated as one tablespoon."],
    )


def normalizer(value: NutritionNormalization) -> RecipeNutritionNormalizer:
    return RecipeNutritionNormalizer(
        client=Client(value),
        model_id="google/gemini-3.7-flash",
        max_tokens=5000,
    )


def test_estimated_yield_and_ingredient_grams_are_applied() -> None:
    result = normalizer(response()).normalize(
        template(servings="1", basis="estimatedFromYield"),
        context=context(),
        job_id=uuid4(),
    )

    assert result.template.servings == 4
    assert result.template.servings_basis == "estimatedFromYield"
    assert result.template.ingredients[0].metric_amount == Decimal("396.9")
    assert result.template.ingredients[1].metric_amount == Decimal("13.6")
    assert result.template.ingredients[1].metric_unit == "g"
    assert result.template.ingredients[1].quantity_text is None
    assert result.template.ingredients[1].uncertainty is not None
    assert result.servings_confidence == Decimal("0.95")
    assert result.assumptions == ("Vegetable oil estimated as one tablespoon.",)


def test_stated_servings_and_raw_quantities_are_protected() -> None:
    result = normalizer(response(servings="8")).normalize(
        template(servings="2", basis="stated"),
        context=context(),
        job_id=uuid4(),
    )

    assert result.template.servings == 2
    assert result.template.servings_basis == "stated"
    assert result.template.ingredients[0].quantity_text == "14 oz"
    assert result.template.ingredients[0].normalized_quantity == 14
    assert result.servings_confidence == 1


def test_explicit_normalizer_exclusions_are_applied_for_calculation() -> None:
    value = response().model_copy(
        update={
            "ingredients": response().ingredients[:1],
            "excluded_ingredient_indexes": [1],
        }
    )

    result = normalizer(value).normalize(
        template(servings="1", basis="estimatedFromYield"),
        context=context(),
        job_id=uuid4(),
    )

    assert result.template.ingredients[1].exclude_from_nutrition
    assert not result.template.ingredients[0].exclude_from_nutrition


def test_model_may_account_for_an_original_to_taste_ingredient() -> None:
    value = response().model_copy(
        update={
            "ingredients": [
                *response().ingredients,
                NormalizedIngredient(
                    ingredient_index=2,
                    usda_search_term="table salt",
                    grams=Decimal("3"),
                    was_inferred=True,
                    rationale="A bounded seasoning estimate.",
                ),
            ]
        }
    )

    result = normalizer(value).normalize(
        template(servings="1", basis="estimatedFromYield"),
        context=context(),
        job_id=uuid4(),
    )

    assert not result.template.ingredients[2].is_to_taste
    assert result.template.ingredients[2].metric_amount == 3


@pytest.mark.parametrize(
    "value",
    [
        NutritionNormalization(
            servings=4,
            servings_confidence=0.8,
            servings_rationale="Four portions.",
            ingredients=[],
            excluded_ingredient_indexes=[],
            assumptions=[],
        ),
        NutritionNormalization(
            servings=4,
            servings_confidence=0.8,
            servings_rationale="Four portions.",
            ingredients=[
                NormalizedIngredient(
                    ingredient_index=9,
                    usda_search_term="noodles",
                    grams=400,
                    was_inferred=False,
                    rationale="Direct conversion.",
                )
            ],
            excluded_ingredient_indexes=[0, 1],
            assumptions=[],
        ),
    ],
    ids=["missing-material", "out-of-range"],
)
def test_invalid_ingredient_coverage_is_rejected(
    value: NutritionNormalization,
) -> None:
    with pytest.raises(NutritionNormalizationUnavailable):
        normalizer(value).normalize(
            template(servings="1", basis="estimatedFromYield"),
            context=context(),
            job_id=uuid4(),
        )
