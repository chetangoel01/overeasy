from decimal import Decimal

from ladle.acquisition.models import AcquiredVideoContext
from ladle.contracts.recipes import (
    FieldUncertaintyDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.extraction.models import RecipeExtraction
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrient,
    TemplateNutrition,
    TemplateStep,
    TemplateTimer,
)

_CONFIDENCE_THRESHOLD = 0.7
_MISSING_QUANTITY_THRESHOLD = 0.3
# Review is a claim that the cook should check something before trusting the
# recipe. Every caveat used to raise it, including ones that say nothing about
# the dish — an unavailable visual provider, a serving count we estimated and
# labelled as estimated. With those firing on nearly every import, the flag
# stopped distinguishing anything. Only caveats that could actually mislead
# someone cooking from the result raise it now; the rest are still recorded
# and still shown beside the field they belong to.
# Finished main-dish weight per adult serving. Deliberately generous: a low
# divisor over-reports servings, which understates per-serving nutrition.
_GRAMS_PER_SERVING = Decimal(400)
_MAX_ESTIMATED_SERVINGS = Decimal(12)


def _estimate_servings(extraction: RecipeExtraction) -> Decimal | None:
    """Approximate yield from the ingredients that carry metric amounts.

    Seasonings and garnishes contribute negligible mass, so they are skipped
    to keep the estimate anchored to the substance of the dish.
    """
    total = sum(
        (
            value.metric_amount
            for value in extraction.ingredients
            if value.metric_amount is not None
            and value.metric_unit is not None
            and not value.is_to_taste
        ),
        Decimal(0),
    )
    if total <= 0:
        return None
    estimated = (total / _GRAMS_PER_SERVING).quantize(Decimal("1"))
    if estimated < 1:
        return Decimal(1)
    return min(estimated, _MAX_ESTIMATED_SERVINGS)


def build_reviewed_template(
    extraction: RecipeExtraction,
    *,
    context: AcquiredVideoContext,
) -> RecipeTemplate:
    uncertainties = list(extraction.uncertainties)
    # Reasons a cook could be misled by cooking straight from this, as opposed
    # to caveats worth showing them.
    blocking: list[str] = []
    servings = extraction.servings
    if servings is None:
        # A yield the source never stated is unknown, not one. Downstream
        # scaling and per-serving nutrition would inherit the lie.
        estimated = _estimate_servings(extraction)
        if estimated is None:
            servings = Decimal(1)
            # Presenting a whole dish as one serving misstates every per-serving
            # number the app derives from it.
            blocking.append("servings")
            uncertainties.append(
                FieldUncertaintyDTO(
                    field="servings",
                    reason=(
                        "Serving count was absent and could not be estimated "
                        "from the ingredient amounts."
                    ),
                )
            )
        else:
            servings = estimated
            uncertainties.append(
                FieldUncertaintyDTO(
                    field="servings",
                    reason=(
                        "Serving count was absent; estimated from the total "
                        "ingredient yield."
                    ),
                )
            )
    elif extraction.servings_basis == "estimatedFromYield":
        uncertainties.append(
            FieldUncertaintyDTO(
                field="servings",
                reason="Serving count was estimated from the recipe yield.",
            )
        )

    quantified = [value for value in extraction.ingredients if not value.is_to_taste]
    missing_quantities = sum(
        value.quantity_text is None and value.normalized_quantity is None
        for value in quantified
    )
    if quantified and (
        missing_quantities / len(quantified) > _MISSING_QUANTITY_THRESHOLD
    ):
        # Too much of the recipe is unmeasured to cook from without checking.
        blocking.append("ingredientQuantities")
        uncertainties.append(
            FieldUncertaintyDTO(
                field="ingredientQuantities",
                reason="More than 30 percent of ingredients lack quantities.",
            )
        )

    if extraction.method_provenance == "inferred":
        # These steps are our reconstruction, not the creator's method.
        blocking.append("steps")
        uncertainties.append(
            FieldUncertaintyDTO(
                field="steps",
                reason=(
                    "The source did not describe a method; these steps were "
                    "reconstructed and need your review."
                ),
            )
        )
    elif extraction.method_provenance == "partial":
        uncertainties.append(
            FieldUncertaintyDTO(
                field="steps",
                reason="Some steps were bridged where the source was silent.",
            )
        )

    if "visualAnalysisUnavailable" in context.diagnostics:
        uncertainties.append(
            FieldUncertaintyDTO(
                field="visualEvidence",
                reason="Visual analysis was unavailable.",
            )
        )

    ingredients: list[TemplateIngredient] = []
    for index, ingredient_value in enumerate(extraction.ingredients):
        uncertainty = None
        if (
            ingredient_value.confidence < _CONFIDENCE_THRESHOLD
            or ingredient_value.uncertainty_reason
        ):
            uncertainty = FieldUncertaintyDTO(
                field=f"ingredients[{index}]",
                reason=ingredient_value.uncertainty_reason
                or "Model confidence is below 0.7.",
                confidence=ingredient_value.confidence,
            )
        ingredients.append(
            TemplateIngredient(
                quantity_text=ingredient_value.quantity_text,
                normalized_quantity=ingredient_value.normalized_quantity,
                unit=ingredient_value.unit,
                name=ingredient_value.name,
                preparation=ingredient_value.preparation,
                order_index=index,
                uncertainty=uncertainty,
            )
        )

    steps: list[TemplateStep] = []
    for index, step_value in enumerate(extraction.steps):
        valid_references = [
            ingredient_index
            for ingredient_index in step_value.ingredient_indices
            if 0 <= ingredient_index < len(ingredients)
        ]
        reasons: list[str] = []
        if len(valid_references) != len(step_value.ingredient_indices):
            reasons.append("Unknown ingredient references were removed.")
        if step_value.confidence < _CONFIDENCE_THRESHOLD:
            reasons.append("Model confidence is below 0.7.")
        if step_value.uncertainty_reason:
            reasons.append(step_value.uncertainty_reason)
        uncertainty = (
            FieldUncertaintyDTO(
                field=f"steps[{index}]",
                reason=" ".join(reasons),
                confidence=step_value.confidence,
            )
            if reasons
            else None
        )
        steps.append(
            TemplateStep(
                order_index=index,
                instruction=step_value.instruction,
                ingredient_indexes=list(dict.fromkeys(valid_references)),
                timers=[
                    TemplateTimer(
                        label=timer.label,
                        duration_seconds=timer.duration_seconds,
                    )
                    for timer in step_value.timers
                ],
                source_start_seconds=step_value.source_start_seconds,
                source_end_seconds=step_value.source_end_seconds,
                uncertainty=uncertainty,
            )
        )

    nutrition = extraction.nutrition
    template_nutrition = (
        TemplateNutrition(
            calories=nutrition.calories,
            protein_grams=nutrition.protein_grams,
            carbohydrate_grams=nutrition.carbohydrate_grams,
            fat_grams=nutrition.fat_grams,
            saturated_fat_grams=nutrition.saturated_fat_grams,
            fiber_grams=nutrition.fiber_grams,
            sugar_grams=nutrition.sugar_grams,
            sodium_milligrams=nutrition.sodium_milligrams,
            other_nutrients=[
                TemplateNutrient(
                    name=value.name,
                    amount=value.amount,
                    unit=value.unit,
                )
                for value in nutrition.other_nutrients
            ],
            serving_basis=nutrition.serving_basis or servings,
            is_estimated=True,
        )
        if nutrition is not None
        else None
    )

    review_status = (
        RecipeReviewStatus.NEEDS_REVIEW if blocking else RecipeReviewStatus.READY
    )
    return RecipeTemplate(
        title=extraction.title,
        description=extraction.description,
        creator_name=extraction.creator_name or context.creator_name,
        source=RecipeSource(context.source.platform),
        original_url=context.source.canonical_url,
        preparation_minutes=extraction.preparation_minutes,
        cooking_minutes=extraction.cooking_minutes,
        total_minutes=extraction.total_minutes,
        servings=servings,
        ingredients=ingredients,
        steps=steps,
        nutrition=template_nutrition,
        notes=[note for note in (n.strip() for n in extraction.notes) if note],
        review_status=review_status,
        uncertainties=uncertainties,
    )
