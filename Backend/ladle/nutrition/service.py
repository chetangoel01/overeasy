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
    UncountedIngredient,
    material_ingredients,
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

        uncounted: list[UncountedIngredient] = []
        try:
            nutrition = self._calculator.calculate_required(
                normalized.template,
                uncounted=uncounted,
            )
        except ProviderUnavailable:
            return _blocked(normalized.template, "usdaUnavailable")
        except NutritionCalculationUnavailable as error:
            reason = error.code
            if error.code == "insufficientCoverage" and uncounted:
                names = ", ".join(value.name for value in uncounted)
                reason += f" (not counted: {names})"
            if error.ingredient_index is not None:
                reason += f" at ingredient {error.ingredient_index}"
            if error.ingredient_name is not None:
                reason += f" ({error.ingredient_name})"
            return _blocked(normalized.template, reason)

        evidence = _evidence(nutrition, normalized)
        enriched = nutrition.model_copy(update={"evidence": evidence})
        return _with_nutrition(normalized.template, enriched, uncounted)


def _owned(field: str) -> bool:
    """Whether nutrition enrichment is the author of this uncertainty.

    Re-enrichment reads a stored recipe back into a template, last run's
    notes included, so anything this module writes has to be cleared before
    it writes again or a recipe accumulates contradictory advice. The
    normalizer's own `ingredients[i].nutritionAmount` is deliberately not
    matched: it belongs to the amount estimate, not to the lookup.
    """
    return field == "nutrition" or field.endswith((".nutrition", ".nutritionMatch"))


def _cleared(template: RecipeTemplate) -> RecipeTemplate:
    return template.model_copy(
        update={
            "uncertainties": [
                value for value in template.uncertainties if not _owned(value.field)
            ],
            "ingredients": [
                value.model_copy(update={"uncertainty": None})
                if value.uncertainty is not None and _owned(value.uncertainty.field)
                else value
                for value in template.ingredients
            ],
        }
    )


def _blocked(template: RecipeTemplate, reason: str) -> RecipeTemplate:
    cleared = _cleared(template)
    return cleared.model_copy(
        update={
            "nutrition": None,
            "uncertainties": [
                *cleared.uncertainties,
                FieldUncertaintyDTO(
                    field="nutrition",
                    reason=f"Nutrition enrichment blocked: {reason}.",
                ),
            ],
        }
    )


def _with_nutrition(
    template: RecipeTemplate,
    nutrition: TemplateNutrition,
    uncounted: list[UncountedIngredient] | None = None,
) -> RecipeTemplate:
    records = uncounted or []
    cleared = _cleared(template)
    uncertainties = list(cleared.uncertainties)
    ingredients = list(cleared.ingredients)
    # An ingredient nothing could cost is left out of the totals rather than
    # voiding them, so the reader has to be told which one and where. The
    # note goes on the row a cook is reading and into the recipe's list,
    # which is the channel the nutrition panel reads.
    for record in records:
        note = FieldUncertaintyDTO(
            field=f"ingredients[{record.index}].nutrition",
            reason=f"Not counted: no nutrition record found for {record.name}.",
        )
        uncertainties.append(note)
        # An ingredient carries one note, shared with extraction's own doubt
        # about the row. The newer note wins: someone reading a total that
        # leaves this ingredient out needs that before a confidence score.
        ingredients[record.index] = ingredients[record.index].model_copy(
            update={"uncertainty": note}
        )
    if records:
        names = ", ".join(record.name for record in records)
        uncertainties.append(
            FieldUncertaintyDTO(
                field="nutrition",
                reason=(
                    f"{len(records)} of {len(material_ingredients(template))} "
                    f"ingredients not counted: {names}."
                ),
            )
        )
    return cleared.model_copy(
        update={
            "nutrition": nutrition,
            "ingredients": ingredients,
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
