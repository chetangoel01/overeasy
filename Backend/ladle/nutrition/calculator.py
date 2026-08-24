"""Whole-recipe macro calculation that refuses unsupported conversions."""

import re
from decimal import ROUND_HALF_UP, Decimal

from ladle.nutrition.usda import FoodDataSource, FoodNutrients, FoodPortion
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
)

_DATA_TYPE_PRIORITY = {
    "Foundation": 0,
    "SR Legacy": 1,
    "Survey (FNDDS)": 2,
    "Branded": 3,
}
_MASS_TO_GRAMS = {
    "g": Decimal(1),
    "gram": Decimal(1),
    "kg": Decimal(1000),
    "kilogram": Decimal(1000),
    "oz": Decimal("28.349523125"),
    "ounce": Decimal("28.349523125"),
    "lb": Decimal("453.59237"),
    "pound": Decimal("453.59237"),
}
_UNIT_ALIASES = {
    "tablespoon": "tbsp",
    "tbs": "tbsp",
    "tbsp": "tbsp",
    "teaspoon": "tsp",
    "tsp": "tsp",
    "cups": "cup",
    "cup": "cup",
    "pieces": "piece",
    "piece": "piece",
    "slices": "slice",
    "slice": "slice",
    "milliliter": "ml",
    "millilitre": "ml",
    "ml": "ml",
}
_QUANTUM = Decimal("0.1")


class NutritionCalculator:
    def __init__(self, source: FoodDataSource) -> None:
        self._source = source

    def calculate(self, template: RecipeTemplate) -> TemplateNutrition | None:
        if (
            template.nutrition is not None
            and template.nutrition.basis == "creatorStated"
        ):
            return template.nutrition
        if template.servings_basis != "stated" or template.servings <= 0:
            return None

        totals = [Decimal(0), Decimal(0), Decimal(0), Decimal(0)]
        food_ids: list[int] = []
        material = [value for value in template.ingredients if not value.is_to_taste]
        if not material:
            return None
        for ingredient in material:
            food = self._food(ingredient)
            if food is None or not _consistent(food):
                return None
            grams = _grams(ingredient, food.portions)
            if grams is None or grams <= 0:
                return None
            scale = grams / Decimal(100)
            values = (
                food.calories_per_100g,
                food.protein_grams_per_100g,
                food.carbohydrate_grams_per_100g,
                food.fat_grams_per_100g,
            )
            totals = [
                total + value * scale
                for total, value in zip(totals, values, strict=True)
            ]
            food_ids.append(food.fdc_id)

        per_serving = [
            (value / template.servings).quantize(_QUANTUM, rounding=ROUND_HALF_UP)
            for value in totals
        ]
        evidence = ", ".join(f"USDA FDC {value}" for value in dict.fromkeys(food_ids))
        return TemplateNutrition(
            calories=per_serving[0],
            protein_grams=per_serving[1],
            carbohydrate_grams=per_serving[2],
            fat_grams=per_serving[3],
            serving_basis=Decimal(1),
            is_estimated=True,
            basis="usdaCalculated",
            evidence=evidence,
        )

    def _food(self, ingredient: TemplateIngredient) -> FoodNutrients | None:
        query = ingredient.usda_search_term
        if query is None:
            return None
        query_tokens = set(_tokens(query))
        if not query_tokens:
            return None
        ranked: list[tuple[tuple[int, int, int], FoodNutrients]] = []
        normalized_query = " ".join(_tokens(query))
        for candidate in self._source.candidates(query):
            description_tokens = set(_tokens(candidate.description))
            if not query_tokens <= description_tokens:
                continue
            description = " ".join(_tokens(candidate.description))
            rank = (
                0 if normalized_query in description else 1,
                len(description_tokens - query_tokens),
                _DATA_TYPE_PRIORITY[candidate.data_type],
            )
            ranked.append((rank, candidate))
        ranked.sort(key=lambda value: (value[0], value[1].fdc_id))
        if not ranked:
            return None
        if len(ranked) > 1 and ranked[0][0] == ranked[1][0]:
            return None
        return ranked[0][1]


def _grams(
    ingredient: TemplateIngredient,
    portions: list[FoodPortion],
) -> Decimal | None:
    if ingredient.metric_amount is not None and ingredient.metric_unit == "g":
        return ingredient.metric_amount
    if ingredient.metric_amount is not None and ingredient.metric_unit == "ml":
        return _portion_grams(ingredient.metric_amount, "ml", portions)
    if ingredient.normalized_quantity is None or ingredient.unit is None:
        return None
    unit = _unit(ingredient.unit)
    factor = _MASS_TO_GRAMS.get(unit)
    if factor is not None:
        return ingredient.normalized_quantity * factor
    return _portion_grams(ingredient.normalized_quantity, unit, portions)


def _portion_grams(
    quantity: Decimal,
    unit: str,
    portions: list[FoodPortion],
) -> Decimal | None:
    matching = [value for value in portions if _unit(value.measure_unit) == _unit(unit)]
    if len(matching) != 1:
        return None
    portion = matching[0]
    return quantity / portion.amount * portion.gram_weight


def _consistent(food: FoodNutrients) -> bool:
    macro_calories = (
        food.protein_grams_per_100g * 4
        + food.carbohydrate_grams_per_100g * 4
        + food.fat_grams_per_100g * 9
    )
    denominator = max(food.calories_per_100g, macro_calories, Decimal(1))
    return abs(food.calories_per_100g - macro_calories) / denominator <= Decimal("0.25")


def _tokens(value: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", value.casefold())


def _unit(value: str) -> str:
    normalized = " ".join(_tokens(value))
    if normalized.endswith("s") and normalized[:-1] in _MASS_TO_GRAMS:
        normalized = normalized[:-1]
    return _UNIT_ALIASES.get(normalized, normalized)
