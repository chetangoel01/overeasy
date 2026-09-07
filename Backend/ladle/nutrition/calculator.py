"""Whole-recipe macro calculation that refuses unsupported conversions."""

import re
from dataclasses import dataclass
from decimal import ROUND_HALF_UP, Decimal

from ladle.nutrition.curated import CuratedFoodTable
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
    # Curated records never reach the ranking — they are answered before any
    # search happens — but a data type missing from this table would be a
    # KeyError rather than a bad ordering, so it is spelled out.
    "Curated": 4,
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


#: Failures that belong to one ingredient rather than to the recipe. Each
#: one leaves the rest of the dish costable, so the loop records it and
#: carries on instead of throwing the whole calculation away.
_INGREDIENT_CODES = frozenset(
    {"foodNotFound", "ambiguousFoodMatch", "inconsistentNutrients", "missingMass"}
)


@dataclass(frozen=True)
class UncountedIngredient:
    """An ingredient left out of the totals because nothing could cost it.

    Dropping one ingredient beats dropping the recipe: a cook told that the
    curry leaves were not counted still learns what the rest of the dish
    costs. There is no share of the dish that has to match — a stew where
    only the onion matched shows the onion, and the marker beside the number
    carries the doubt. `estimated_grams` is the normalizer's own figure,
    kept because how much went uncounted is worth reporting even though
    nothing is refused for it.
    """

    index: int
    name: str
    code: str
    estimated_grams: Decimal


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
    """Cost a recipe from food records, skipping what no record describes.

    Three rungs, in order. `curated` is the checked-in table of foods USDA
    has no usable record for; it answers first, because asking a search
    engine about garam masala only buys the wrong answer more slowly.
    `source` is USDA. `fallback` is the second provider of the ladder,
    asked only about the ingredients the primary source could not answer, so
    the common case still costs one search per ingredient. It is unset in
    production; the seam exists so adding a provider is a composition change
    rather than a calculator change.
    """

    def __init__(
        self,
        source: FoodDataSource,
        fallback: FoodDataSource | None = None,
        curated: CuratedFoodTable | None = None,
    ) -> None:
        self._source = source
        self._fallback = fallback
        self._curated = curated

    def calculate(self, template: RecipeTemplate) -> TemplateNutrition | None:
        try:
            return self.calculate_required(template)
        except NutritionCalculationUnavailable:
            return None

    def calculate_required(
        self,
        template: RecipeTemplate,
        *,
        uncounted: list[UncountedIngredient] | None = None,
    ) -> TemplateNutrition | None:
        """Cost the recipe, appending what it could not cost to `uncounted`.

        The list is an out-parameter rather than part of the return value
        because `TemplateNutrition` goes on the wire, and a caller that does
        not care which ingredients were skipped should not have to unpack a
        wrapper. It is filled whichever way this ends.

        `None` means nothing matched, so there was nothing to total — the
        one empty result that is not a failure. The exceptions left are the
        recipe's own: a yield no serving can be derived from and a recipe
        with no material ingredients at all.
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

        records = uncounted if uncounted is not None else []
        totals = [Decimal(0), Decimal(0), Decimal(0), Decimal(0)]
        foods: list[str] = []
        material = material_ingredients(template)
        if not material:
            raise NutritionCalculationUnavailable("noMaterialIngredients")
        for index, ingredient in material:
            try:
                cited, food, grams = self._matched(ingredient, index=index)
            except NutritionCalculationUnavailable as error:
                if error.code not in _INGREDIENT_CODES:
                    raise
                records.append(
                    UncountedIngredient(
                        index=index,
                        name=ingredient.name,
                        code=error.code,
                        estimated_grams=estimated_grams(ingredient),
                    )
                )
                continue
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
            foods.append(cited)

        if not foods:
            return None
        per_serving = [
            (value / template.servings).quantize(_QUANTUM, rounding=ROUND_HALF_UP)
            for value in totals
        ]
        evidence = ", ".join(dict.fromkeys(foods))
        return TemplateNutrition(
            calories=per_serving[0],
            protein_grams=per_serving[1],
            carbohydrate_grams=per_serving[2],
            fat_grams=per_serving[3],
            serving_basis=Decimal(1),
            is_estimated=True,
            # Approximate is not the same claim as estimated. Every
            # calculated block is estimated; this one is also missing
            # ingredients, which is what the marker beside the number says.
            approximate=bool(records),
            basis="usdaCalculated",
            evidence=evidence,
        )

    def _matched(
        self,
        ingredient: TemplateIngredient,
        *,
        index: int,
    ) -> tuple[str, FoodNutrients, Decimal]:
        """The first rung that can cost this ingredient, and its answer.

        The curated table goes first and wins outright where it has a row:
        it is there precisely because the search below it answers these
        foods wrongly, so falling through would spend a lookup to be told
        something already known to be false. A curated row that cannot be
        weighed fails as `missingMass` rather than dropping to USDA — the
        fix is a portion in the table, and reporting it as `foodNotFound`
        would put the food back on the ops panel's list of rows to add.

        USDA answers almost everything else. A fallback, where one is
        configured, only sees the ingredients that came back with nothing
        usable — including the ones whose closest record does not describe
        them, since costing a vegetarian curry from `Beef curry` is not an
        imprecise number but a wrong one.

        The string returned is the citation for the evidence line, which has
        to say which rung answered or the panel stops being checkable.
        """
        curated = (
            self._curated.lookup(ingredient.name, ingredient.usda_search_term)
            if self._curated is not None
            else None
        )
        if curated is not None:
            grams = _grams(ingredient, curated.portions)
            if grams is None or grams <= 0:
                raise NutritionCalculationUnavailable(
                    "missingMass",
                    ingredient_index=index,
                    ingredient_name=ingredient.name,
                )
            return f"{CuratedFoodTable.name} {curated.description}", curated, grams
        try:
            food, grams = self._usable_food(self._source, ingredient, index=index)
        except NutritionCalculationUnavailable as error:
            if self._fallback is None or error.code not in _INGREDIENT_CODES:
                raise
            food, grams = self._usable_food(self._fallback, ingredient, index=index)
            return f"{self._fallback.name} {food.fdc_id}", food, grams
        return f"{self._source.name} {food.fdc_id}", food, grams

    def _usable_food(
        self,
        source: FoodDataSource,
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
        candidates = self._ranked_candidates(source, ingredient, index=index)
        query = ingredient.usda_search_term or ""
        # Relevance orders the candidates before it rejects any, so reaching
        # an irrelevant one means every relevant candidate was unusable.
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
            if not _relevant(query, food.description):
                first_failure = first_failure or NutritionCalculationUnavailable(
                    "foodNotFound",
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
        source: FoodDataSource,
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
        candidates = source.candidates(query)
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


def material_ingredients(
    template: RecipeTemplate,
) -> list[tuple[int, TemplateIngredient]]:
    """The ingredients a calorie total is built from, with their positions.

    Salt to taste and water carry no calories worth chasing and are excluded
    upstream; a note saying "1 of 12 not counted" has to be measured against
    the same set the calculator worked on, so both sides read it from here.
    """
    return [
        (index, value)
        for index, value in enumerate(template.ingredients)
        if not value.is_to_taste and not value.exclude_from_nutrition
    ]


def estimated_grams(ingredient: TemplateIngredient) -> Decimal:
    """The normalizer's own mass estimate, in grams.

    Public because the refresh script reports how much of a real library
    goes uncounted, and an ops panel counting misses is worth more when it
    can say how heavy they were.

    An unmatched ingredient cannot be weighed with `_grams`: that needs a
    food's portion table, which nothing matched. Normalization writes grams
    for every ingredient it keeps, and where it did not the ingredient
    weighs nothing rather than guessing at it.
    """
    if ingredient.metric_amount is not None and ingredient.metric_unit == "g":
        return ingredient.metric_amount
    return Decimal(0)


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
