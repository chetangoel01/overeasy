"""Whole-recipe macro calculation that refuses unsupported conversions."""

import re
from dataclasses import dataclass
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


@dataclass(frozen=True)
class WeakFoodMatch:
    """An ingredient costed from a food that does not obviously match it.

    Recorded rather than raised. Blocking would lose every other ingredient's
    calories over one blend USDA has no entry for, and accepting it silently
    would present a number nobody should trust as though it were measured.
    """

    ingredient_index: int
    ingredient_name: str
    description: str


class NutritionCalculationUnavailable(Exception):
    """A deterministic nutrition calculation could not be completed."""

    def __init__(
        self,
        code: str,
        *,
        ingredient_index: int | None = None,
        ingredient_name: str | None = None,
    ) -> None:
        self.code = code
        self.ingredient_index = ingredient_index
        self.ingredient_name = ingredient_name
        location = (
            f" for ingredient {ingredient_index} ({ingredient_name})"
            if ingredient_index is not None and ingredient_name is not None
            else ""
        )
        super().__init__(f"{code}{location}")


class NutritionCalculator:
    def __init__(self, source: FoodDataSource) -> None:
        self._source = source

    def calculate(self, template: RecipeTemplate) -> TemplateNutrition | None:
        try:
            return self.calculate_required(template)
        except NutritionCalculationUnavailable:
            return None

    def calculate_required(
        self,
        template: RecipeTemplate,
        *,
        weak_matches: list[WeakFoodMatch] | None = None,
    ) -> TemplateNutrition:
        """Cost the recipe, appending any doubtful match to `weak_matches`.

        The list is an out-parameter rather than part of the return value
        because `TemplateNutrition` goes on the wire, and a caller that does
        not care about match quality should not have to unpack a wrapper.
        """
        if (
            template.nutrition is not None
            and template.nutrition.basis == "creatorStated"
        ):
            return template.nutrition
        if (
            template.servings_basis not in {"stated", "estimatedFromYield"}
            or template.servings <= 0
        ):
            raise NutritionCalculationUnavailable("invalidYield")

        totals = [Decimal(0), Decimal(0), Decimal(0), Decimal(0)]
        food_ids: list[int] = []
        material = [
            (index, value)
            for index, value in enumerate(template.ingredients)
            if not value.is_to_taste and not value.exclude_from_nutrition
        ]
        if not material:
            raise NutritionCalculationUnavailable("noMaterialIngredients")
        for index, ingredient in material:
            food, grams = self._usable_food(ingredient, index=index)
            query = ingredient.usda_search_term or ""
            if weak_matches is not None and not _relevant(query, food.description):
                weak_matches.append(
                    WeakFoodMatch(
                        ingredient_index=index,
                        ingredient_name=ingredient.name,
                        description=food.description,
                    )
                )
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

    def _usable_food(
        self,
        ingredient: TemplateIngredient,
        *,
        index: int,
    ) -> tuple[FoodNutrients, Decimal]:
        """The best-ranked candidate whose nutrients and mass are both usable.

        USDA's top hit is regularly a branded product with a nonsense
        per-100g panel — a spice grinder refill declaring zero calories and
        133g of carbohydrate outranked `Spices, cumin seed` on a literal
        token match. Taking only the first candidate meant one such record
        cost the whole recipe its nutrition, so every candidate the search
        already paid for is tried in rank order before giving up. The failure
        reported when none work is the first candidate's, which is the one
        the ranking believed in.
        """
        candidates = self._ranked_candidates(ingredient, index=index)
        query = ingredient.usda_search_term or ""
        # Relevance orders the candidates; it never removes them. A blend USDA
        # has no entry for still gets costed from its closest row, and the
        # caller is told the match was weak.
        candidates = [
            food for food in candidates if _relevant(query, food.description)
        ] + [food for food in candidates if not _relevant(query, food.description)]
        first_failure: NutritionCalculationUnavailable | None = None
        for food in candidates:
            if not _consistent(food, query=ingredient.usda_search_term or ""):
                first_failure = first_failure or NutritionCalculationUnavailable(
                    "inconsistentNutrients",
                    ingredient_index=index,
                    ingredient_name=ingredient.name,
                )
                continue
            grams = _grams(ingredient, food.portions)
            if grams is None or grams <= 0:
                first_failure = first_failure or NutritionCalculationUnavailable(
                    "missingMass",
                    ingredient_index=index,
                    ingredient_name=ingredient.name,
                )
                continue
            return food, grams
        raise first_failure or NutritionCalculationUnavailable(
            "foodNotFound",
            ingredient_index=index,
            ingredient_name=ingredient.name,
        )

    def _ranked_candidates(
        self,
        ingredient: TemplateIngredient,
        *,
        index: int,
    ) -> list[FoodNutrients]:
        query = ingredient.usda_search_term
        if query is None:
            raise NutritionCalculationUnavailable(
                "foodNotFound",
                ingredient_index=index,
                ingredient_name=ingredient.name,
            )
        query_tokens = set(_tokens(query))
        if not query_tokens:
            raise NutritionCalculationUnavailable(
                "foodNotFound",
                ingredient_index=index,
                ingredient_name=ingredient.name,
            )
        candidates = self._source.candidates(query)
        provider_ranked = [
            value for value in candidates if value.search_rank is not None
        ]
        if provider_ranked:
            provider_ranked.sort(
                key=lambda value: (
                    value.search_rank if value.search_rank is not None else 0,
                    value.fdc_id,
                )
            )
            return provider_ranked

        ranked: list[tuple[tuple[int, int, int], FoodNutrients]] = []
        normalized_query = " ".join(_tokens(query))
        for candidate in candidates:
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
            raise NutritionCalculationUnavailable(
                "foodNotFound",
                ingredient_index=index,
                ingredient_name=ingredient.name,
            )
        if len(ranked) > 1 and ranked[0][0] == ranked[1][0]:
            raise NutritionCalculationUnavailable(
                "ambiguousFoodMatch",
                ingredient_index=index,
                ingredient_name=ingredient.name,
            )
        return [value for _, value in ranked]


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


def _consistent(food: FoodNutrients, *, query: str = "") -> bool:
    """Whether stated calories agree with the macronutrients beside them.

    Fibre is why this is a band rather than a single number. Atwater charges
    every gram of carbohydrate 4 kcal, but fibre is largely unavailable and
    USDA's stated calories reflect that, so a high-fibre food looks wildly
    inconsistent under the naive sum: `Spices, cloves, ground` states 274 kcal
    against a naive 403, and was rejected for 32% disagreement despite being a
    laboratory record. Treating fibre as free gives 267.

    A panel is consistent when its stated energy lies between those two, or
    within the tolerance of the nearer edge. Where fibre is unreported the
    band collapses to the naive sum, which is the behaviour this replaces.
    """
    if set(_tokens(query)) & {"alcohol", "beer", "liquor", "vinegar", "wine"}:
        return True
    upper = (
        food.protein_grams_per_100g * 4
        + food.carbohydrate_grams_per_100g * 4
        + food.fat_grams_per_100g * 9
    )
    fibre = min(
        food.fibre_grams_per_100g or Decimal(0), food.carbohydrate_grams_per_100g
    )
    lower = upper - fibre * 4
    energy = food.calories_per_100g
    if lower <= energy <= upper:
        return True
    nearest = lower if energy < lower else upper
    denominator = max(energy, nearest, Decimal(1))
    return abs(energy - nearest) / denominator <= Decimal("0.25")


def _tokens(value: str) -> list[str]:
    return re.findall(r"[a-z0-9]+", value.casefold())


def _stems(value: str) -> set[str]:
    """Tokens with a trailing plural folded away.

    "seeds" against "Spices, cumin seed" is what started all of this: one
    character kept a laboratory record from matching the ingredient it
    describes.
    """
    return {
        token[:-1] if len(token) > 3 and token.endswith("s") else token
        for token in _tokens(value)
    }


#: Mutually exclusive states. A record in one of these cannot answer a query
#: asking for another: dried coriander leaf is 279 kcal per 100g and the fresh
#: herb is about 23, so agreeing on "coriander" and "leaf" is not enough.
_STATES: dict[str, str] = {
    "raw": "raw",
    "fresh": "raw",
    "dried": "dried",
    "dehydrated": "dried",
    "canned": "canned",
    "frozen": "frozen",
    "cooked": "cooked",
    "boiled": "cooked",
    "roasted": "cooked",
}


def _states(stems: set[str]) -> set[str]:
    return {_STATES[stem] for stem in stems if stem in _STATES}


def _relevant(query: str, description: str) -> bool:
    """Whether a candidate plausibly describes the ingredient asked for.

    USDA's own ranking answers "cinnamon stick" with APPLEBEE'S mozzarella
    sticks and "ginger garlic paste" with almond paste, and nothing on the
    provider-ranked path checked. A candidate qualifies when it carries the
    query's distinguishing word — every query token for a single-word query,
    and more than half for a longer one, since USDA writes "Spices, cinnamon,
    ground" where a cook writes "cinnamon stick".
    """
    tokens = [
        token[:-1] if len(token) > 3 and token.endswith("s") else token
        for token in _tokens(query)
    ]
    if not tokens:
        return False
    described = _stems(description)
    # The first word names the food; the rest qualify it. Sharing only the
    # qualifiers is how "coriander leaf raw" matched "Lettuce, leaf, green,
    # raw" — two words of three agreed, and the one that did not was the only
    # one that mattered.
    if tokens[0] not in described:
        return False
    wanted = set(tokens)
    asked = _states(wanted)
    offered = _states(described)
    if asked and offered and not (asked & offered):
        return False
    shared = wanted & described
    if len(wanted) == 1:
        return bool(shared)
    return len(shared) * 2 > len(wanted)


def _unit(value: str) -> str:
    normalized = " ".join(_tokens(value))
    if normalized.endswith("s") and normalized[:-1] in _MASS_TO_GRAMS:
        normalized = normalized[:-1]
    return _UNIT_ALIASES.get(normalized, normalized)
