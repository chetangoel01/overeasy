"""Nutrition enrichment composed from model normalization and USDA facts."""

from __future__ import annotations

from typing import Protocol
from uuid import UUID

from ladle.acquisition.errors import ProviderUnavailable
from ladle.acquisition.models import AcquiredVideoContext
from ladle.contracts.recipes import FieldUncertaintyDTO, RecipeReviewStatus
from ladle.nutrition.calculator import (
    NutritionCalculationUnavailable,
    NutritionCalculator,
    WeakFoodMatch,
)
from ladle.nutrition.normalization import (
    NormalizedRecipe,
    NutritionNormalizationUnavailable,
)
from ladle.recipes.template_clone import RecipeTemplate, TemplateNutrition


class NutritionNormalizer(Protocol):
    def normalize(
        self,
        template: RecipeTemplate,
        *,
        context: AcquiredVideoContext,
        job_id: UUID,
    ) -> NormalizedRecipe: ...


class RecipeNutritionService:
    def __init__(
        self,
        *,
        normalizer: NutritionNormalizer,
        calculator: NutritionCalculator,
    ) -> None:
        self._normalizer = normalizer
        self._calculator = calculator

    def enrich(
        self,
        template: RecipeTemplate,
        *,
        context: AcquiredVideoContext,
        job_id: UUID,
    ) -> RecipeTemplate:
        if (
            template.nutrition is not None
            and template.nutrition.basis == "creatorStated"
        ):
            return _with_nutrition(template, template.nutrition)

        try:
            normalized = self._normalizer.normalize(
                template,
                context=context,
                job_id=job_id,
            )
        except NutritionNormalizationUnavailable as error:
            return _blocked(template, f"normalizationUnavailable ({error})")

        weak_matches: list[WeakFoodMatch] = []
        try:
            nutrition = self._calculator.calculate_required(
                normalized.template,
                weak_matches=weak_matches,
            )
        except ProviderUnavailable:
            return _blocked(normalized.template, "usdaUnavailable")
        except NutritionCalculationUnavailable as error:
            reason = error.code
            if error.ingredient_index is not None:
                reason += f" at ingredient {error.ingredient_index}"
            if error.ingredient_name is not None:
                reason += f" ({error.ingredient_name})"
            return _blocked(normalized.template, reason)

        evidence = _evidence(nutrition, normalized)
        enriched = nutrition.model_copy(update={"evidence": evidence})
        return _with_nutrition(normalized.template, enriched, weak_matches)


def _blocked(template: RecipeTemplate, reason: str) -> RecipeTemplate:
    uncertainties = [
        value for value in template.uncertainties if value.field != "nutrition"
    ]
    uncertainties.append(
        FieldUncertaintyDTO(
            field="nutrition",
            reason=f"Nutrition enrichment blocked: {reason}.",
        )
    )
    return template.model_copy(
        update={
            "nutrition": None,
            "uncertainties": uncertainties,
        }
    )


def _with_nutrition(
    template: RecipeTemplate,
    nutrition: TemplateNutrition,
    weak_matches: list[WeakFoodMatch] | None = None,
) -> RecipeTemplate:
    uncertainties = [
        value for value in template.uncertainties if value.field != "nutrition"
    ]
    # A doubtful match is surfaced rather than hidden. The totals are still
    # worth showing — one unmatched blend should not cost the dish its
    # calories — but the reader is told which ingredient they rest on.
    for match in weak_matches or []:
        uncertainties.append(
            FieldUncertaintyDTO(
                field=f"ingredients[{match.ingredient_index}].nutritionMatch",
                reason=(
                    f"Closest USDA record for {match.ingredient_name} was "
                    f"{match.description}, which may not describe it."
                ),
            )
        )
    return template.model_copy(
        update={
            "nutrition": nutrition,
            "review_status": (
                RecipeReviewStatus.READY
                if not uncertainties
                else template.review_status
            ),
            "uncertainties": uncertainties,
        }
    )


def _evidence(
    nutrition: TemplateNutrition,
    normalized: NormalizedRecipe,
) -> str:
    confidence_value = (normalized.servings_confidence * 100).normalize()
    confidence = f"{confidence_value:f}%"
    values = [
        nutrition.evidence or "USDA FoodData Central",
        f"Serving estimate confidence: {confidence}",
        f"Yield rationale: {normalized.servings_rationale}",
    ]
    if normalized.assumptions:
        values.append("Assumptions: " + "; ".join(normalized.assumptions))
    return ". ".join(value.rstrip(". ") for value in values) + "."
