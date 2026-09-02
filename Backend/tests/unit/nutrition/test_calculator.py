from dataclasses import dataclass, field
from decimal import Decimal

import pytest

from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.nutrition.calculator import (
    NutritionCalculationUnavailable,
    NutritionCalculator,
    UncountedIngredient,
)
from ladle.nutrition.usda import FoodNutrients, FoodPortion
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
)
from tests.fakes.nutrition import FakeFoodDataSource


@dataclass
class Foods:
    values: dict[str, list[FoodNutrients]]
    calls: list[str] = field(default_factory=list)
    name: str = "USDA FDC"

    def candidates(self, query: str) -> list[FoodNutrients]:
        self.calls.append(query)
        return self.values.get(query, [])


def uncounted_ingredients(
    source: Foods,
    value: TemplateIngredient,
) -> list[UncountedIngredient]:
    """What a one-ingredient recipe could not cost.

    One ingredient is the whole of such a recipe's mass, so failing to cost
    it always trips the coverage floor. The records are still written before
    the raise, which is what these tests are about.
    """
    records: list[UncountedIngredient] = []
    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(source).calculate_required(
            recipe([value]),
            uncounted=records,
        )
    assert error.value.code == "insufficientCoverage"
    return records


def portion(
    unit: str,
    grams: str,
    *,
    amount: str = "1",
    modifier: str | None = None,
) -> FoodPortion:
    return FoodPortion(
        amount=Decimal(amount),
        gram_weight=Decimal(grams),
        measure_unit=unit,
        modifier=modifier,
    )


def food(
    *,
    fdc_id: int = 1,
    description: str = "chickpeas drained",
    data_type: str = "Foundation",
    calories: str = "140",
    protein: str = "10",
    carbohydrate: str = "20",
    fat: str = "2",
    fibre: str | None = None,
    portions: list[FoodPortion] | None = None,
    search_rank: int | None = None,
) -> FoodNutrients:
    return FoodNutrients.model_validate(
        {
            "fdc_id": fdc_id,
            "description": description,
            "data_type": data_type,
            "calories_per_100g": Decimal(calories),
            "protein_grams_per_100g": Decimal(protein),
            "carbohydrate_grams_per_100g": Decimal(carbohydrate),
            "fat_grams_per_100g": Decimal(fat),
            "fibre_grams_per_100g": Decimal(fibre) if fibre else None,
            "portions": portions or [],
            "search_rank": search_rank,
        }
    )


def ingredient(
    *,
    name: str = "chickpeas",
    query: str = "chickpeas drained",
    quantity: str | None = "200",
    unit: str | None = "g",
    metric_amount: str | None = "200",
    metric_unit: str | None = "g",
    is_to_taste: bool = False,
    exclude_from_nutrition: bool = False,
    order_index: int = 0,
) -> TemplateIngredient:
    return TemplateIngredient.model_validate(
        {
            "name": name,
            "quantity_text": f"{quantity} {unit}" if quantity and unit else None,
            "normalized_quantity": Decimal(quantity) if quantity else None,
            "unit": unit,
            "metric_amount": Decimal(metric_amount) if metric_amount else None,
            "metric_unit": metric_unit,
            "usda_search_term": query,
            "is_to_taste": is_to_taste,
            "exclude_from_nutrition": exclude_from_nutrition,
            "order_index": order_index,
        }
    )


def recipe(
    ingredients: list[TemplateIngredient],
    *,
    servings: str = "4",
    servings_basis: str = "stated",
    nutrition: TemplateNutrition | None = None,
) -> RecipeTemplate:
    return RecipeTemplate.model_validate(
        {
            "title": "Chickpea Stew",
            "description": "",
            "source": RecipeSource.OTHER,
            "original_url": "https://creator.example/chickpea-stew",
            "servings": Decimal(servings),
            "servings_basis": servings_basis,
            "ingredients": ingredients,
            "steps": [],
            "nutrition": nutrition,
            "review_status": RecipeReviewStatus.READY,
            "uncertainties": [],
        }
    )


def test_calculates_per_serving_nutrition_with_one_serving_basis() -> None:
    source = Foods({"chickpeas drained": [food()]})

    result = NutritionCalculator(source).calculate(recipe([ingredient()]))

    assert result is not None
    assert result.calories == Decimal("70.0")
    assert result.protein_grams == Decimal("5.0")
    assert result.carbohydrate_grams == Decimal("10.0")
    assert result.fat_grams == Decimal("1.0")
    assert result.serving_basis == Decimal("1")
    assert result.basis == "usdaCalculated"
    assert result.is_estimated
    assert "FDC 1" in (result.evidence or "")


@pytest.mark.parametrize(
    ("unit", "quantity", "portion_value", "expected_calories"),
    [
        ("cup", "2", portion("cup", "100"), Decimal("70.0")),
        ("tbsp", "2", portion("tablespoon", "15"), Decimal("10.5")),
        ("piece", "3", portion("piece", "30"), Decimal("31.5")),
    ],
)
def test_uses_usda_portion_weights_for_volume_and_counts(
    unit: str,
    quantity: str,
    portion_value: FoodPortion,
    expected_calories: Decimal,
) -> None:
    value = ingredient(
        quantity=quantity,
        unit=unit,
        metric_amount=None,
        metric_unit=None,
    )
    source = Foods({"chickpeas drained": [food(portions=[portion_value])]})

    result = NutritionCalculator(source).calculate(recipe([value], servings="4"))

    assert result is not None
    assert result.calories == expected_calories


def test_metric_volume_requires_a_matching_usda_volume_portion() -> None:
    value = ingredient(
        quantity=None,
        unit=None,
        metric_amount="100",
        metric_unit="ml",
    )
    source = Foods(
        {"chickpeas drained": [food(portions=[portion("ml", "103", amount="100")])]}
    )

    result = NutritionCalculator(source).calculate(recipe([value], servings="1"))

    assert result is not None
    assert result.calories == Decimal("144.2")


def test_creator_stated_nutrition_takes_precedence_without_usda_calls() -> None:
    creator = TemplateNutrition(
        calories=Decimal("500"),
        protein_grams=Decimal("20"),
        carbohydrate_grams=Decimal("60"),
        fat_grams=Decimal("20"),
        serving_basis=Decimal("4"),
        is_estimated=False,
        basis="creatorStated",
        evidence="Creator nutrition panel.",
    )
    source = Foods({})

    result = NutritionCalculator(source).calculate(
        recipe([ingredient()], nutrition=creator)
    )

    assert result is creator
    assert source.calls == []


def test_equally_specific_generic_matches_are_ambiguous() -> None:
    source = Foods(
        {
            "rice": [
                food(fdc_id=1, description="rice white cooked"),
                food(fdc_id=2, description="rice brown cooked"),
            ]
        }
    )
    value = ingredient(name="rice", query="rice")

    assert NutritionCalculator(source).calculate(recipe([value])) is None

    records = uncounted_ingredients(source, value)

    assert records == [
        UncountedIngredient(
            index=0,
            name="rice",
            code="ambiguousFoodMatch",
            estimated_grams=Decimal("200"),
        )
    ]


def test_trusts_unique_usda_search_order_for_normalized_query() -> None:
    source = Foods(
        {
            "dry wheat noodles": [
                food(
                    fdc_id=10,
                    description="noodles egg dry enriched",
                    search_rank=0,
                ),
                food(
                    fdc_id=11,
                    description="noodles rice cooked",
                    search_rank=1,
                ),
            ]
        }
    )
    value = ingredient(name="noodles", query="dry wheat noodles")

    result = NutritionCalculator(source).calculate_required(recipe([value]))

    assert result.evidence == "USDA FDC 10"


@pytest.mark.parametrize(
    "value",
    [
        ingredient(quantity=None, unit=None, metric_amount=None, metric_unit=None),
        ingredient(quantity="2", unit="scoop", metric_amount=None, metric_unit=None),
    ],
    ids=["missing-quantity", "unsupported-portion"],
)
def test_missing_material_mass_returns_no_nutrition(
    value: TemplateIngredient,
) -> None:
    source = Foods({"chickpeas drained": [food()]})

    assert NutritionCalculator(source).calculate(recipe([value])) is None


def test_estimated_servings_are_used_for_division() -> None:
    source = Foods({"chickpeas drained": [food()]})

    result = NutritionCalculator(source).calculate(
        recipe([ingredient()], servings_basis="estimatedFromYield")
    )

    assert result is not None
    assert result.calories == Decimal("70.0")


def test_unknown_servings_exposes_diagnostic() -> None:
    calculator = NutritionCalculator(Foods({"chickpeas drained": [food()]}))

    with pytest.raises(NutritionCalculationUnavailable) as error:
        calculator.calculate_required(recipe([ingredient()], servings_basis="unknown"))

    assert error.value.code == "invalidYield"
    assert error.value.ingredient_index is None


def test_to_taste_ingredient_is_excluded_without_a_lookup() -> None:
    salt = ingredient(
        name="salt",
        query="salt",
        quantity=None,
        unit=None,
        metric_amount=None,
        metric_unit=None,
        is_to_taste=True,
        order_index=1,
    )
    source = Foods({"chickpeas drained": [food()]})

    result = NutritionCalculator(source).calculate(recipe([ingredient(), salt]))

    assert result is not None
    assert source.calls == ["chickpeas drained"]


def test_explicitly_excluded_water_is_not_looked_up() -> None:
    water = ingredient(
        name="water",
        query="water",
        exclude_from_nutrition=True,
        order_index=1,
    )
    source = Foods({"chickpeas drained": [food()]})

    result = NutritionCalculator(source).calculate(recipe([ingredient(), water]))

    assert result is not None
    assert source.calls == ["chickpeas drained"]


def test_missing_food_match_leaves_the_only_ingredient_uncounted() -> None:
    """The ingredient is dropped, not the calculation — but it is the recipe.

    Nothing is left to total once the single ingredient goes uncounted, so
    the coverage floor blocks the recipe. The record still names it.
    """
    assert NutritionCalculator(Foods({})).calculate(recipe([ingredient()])) is None

    records = uncounted_ingredients(Foods({}), ingredient())

    assert records == [
        UncountedIngredient(
            index=0,
            name="chickpeas",
            code="foodNotFound",
            estimated_grams=Decimal("200"),
        )
    ]


def test_gross_calorie_macro_inconsistency_is_rejected() -> None:
    inconsistent = food(calories="900", protein="1", carbohydrate="1", fat="1")
    source = Foods({"chickpeas drained": [inconsistent]})

    assert NutritionCalculator(source).calculate(recipe([ingredient()])) is None

    records = uncounted_ingredients(source, ingredient())

    assert [(value.name, value.code) for value in records] == [
        ("chickpeas", "inconsistentNutrients")
    ]


@pytest.mark.parametrize("query", ["white table wine", "black vinegar"])
def test_non_macro_energy_sources_use_authoritative_usda_calories(query: str) -> None:
    source = Foods(
        {
            query: [
                food(
                    description=query,
                    calories="80",
                    protein="0",
                    carbohydrate="2",
                    fat="0",
                    search_rank=0,
                )
            ]
        }
    )
    value = ingredient(name=query, query=query, metric_amount="100")

    result = NutritionCalculator(source).calculate_required(
        recipe([value], servings="1")
    )

    assert result.calories == Decimal("80.0")


def test_missing_mass_exposes_ingredient_diagnostic() -> None:
    value = ingredient(
        quantity=None,
        unit=None,
        metric_amount=None,
        metric_unit=None,
    )

    records = uncounted_ingredients(Foods({"chickpeas drained": [food()]}), value)

    assert records == [
        UncountedIngredient(
            index=0,
            name="chickpeas",
            code="missingMass",
            # Nothing said how much of it there was, so it weighs nothing in
            # the coverage ratio either.
            estimated_grams=Decimal(0),
        )
    ]


def test_first_candidate_with_impossible_nutrients_falls_through_to_the_next() -> None:
    # The real failure: USDA's top hit for "cumin seeds" was a branded grinder
    # refill claiming zero calories, while the SR Legacy spice record sat one
    # rank below it. One unusable candidate must not cost the whole recipe.
    junk = food(
        fdc_id=2427784,
        description="CUMIN SEEDS GRINDER REFILL",
        data_type="Branded",
        calories="0",
        protein="0",
        carbohydrate="133.33",
        fat="0",
        search_rank=0,
    )
    usable = food(
        fdc_id=170923,
        description="Spices, cumin seed",
        data_type="SR Legacy",
        calories="375",
        protein="17.81",
        carbohydrate="44.24",
        fat="22.27",
        search_rank=1,
    )
    source = Foods({"cumin seeds": [junk, usable]})

    result = NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="cumin seeds", query="cumin seeds")])
    )

    assert result is not None
    assert "FDC 170923" in (result.evidence or "")
    assert "FDC 2427784" not in (result.evidence or "")


def test_candidate_without_usable_mass_falls_through_to_the_next() -> None:
    unmeasurable = food(fdc_id=11, description="garlic raw", search_rank=0, portions=[])
    usable = food(
        fdc_id=12,
        description="garlic raw",
        search_rank=1,
        portions=[portion("clove", "3")],
    )
    source = Foods({"garlic": [unmeasurable, usable]})

    result = NutritionCalculator(source).calculate_required(
        recipe(
            [
                ingredient(
                    name="garlic",
                    query="garlic",
                    quantity="2",
                    unit="clove",
                    metric_amount=None,
                    metric_unit=None,
                )
            ]
        )
    )

    assert result is not None
    assert "FDC 12" in (result.evidence or "")


def test_every_candidate_being_unusable_uncounts_only_that_ingredient() -> None:
    """The rest of the dish keeps its calories.

    Both candidates for the chickpeas are nonsense panels, so the chickpeas
    go uncounted; the noodles beside them are found and still totalled.
    """
    source = Foods(
        {
            "chickpeas drained": [
                food(
                    fdc_id=21,
                    calories="900",
                    protein="1",
                    carbohydrate="1",
                    fat="1",
                    search_rank=0,
                ),
                food(
                    fdc_id=22,
                    calories="0",
                    protein="0",
                    carbohydrate="125",
                    fat="0",
                    search_rank=1,
                ),
            ],
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ],
        }
    )
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(source).calculate_required(
        recipe(
            [
                ingredient(metric_amount="20", quantity="20"),
                ingredient(
                    name="egg noodles",
                    query="egg noodles dry",
                    metric_amount="400",
                    quantity="400",
                    order_index=1,
                ),
            ]
        ),
        uncounted=records,
    )

    assert result.calories == Decimal("140")
    assert [(value.name, value.code) for value in records] == [
        ("chickpeas", "inconsistentNutrients")
    ]


def test_high_fibre_spices_are_not_rejected_for_counting_fibre_as_sugar() -> None:
    """`Spices, cloves, ground` is a laboratory record, and it used to fail.

    USDA states 274 kcal. Charging its 33.9g of fibre the full 4 kcal/g puts
    the estimate at 403 — 32% away, past the tolerance — while treating fibre
    as unavailable puts it at 267. The stated value sits between those two, so
    the panel is consistent and the recipe should cost it.
    """
    cloves = food(
        fdc_id=171321,
        description="Spices, cloves, ground",
        data_type="SR Legacy",
        calories="274",
        protein="5.97",
        carbohydrate="65.53",
        fat="13.0",
        fibre="33.9",
        search_rank=0,
    )
    source = Foods({"cloves": [cloves]})

    result = NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="cloves", query="cloves")])
    )

    assert result is not None
    assert "FDC 171321" in (result.evidence or "")


def test_a_panel_outside_the_fibre_band_is_still_rejected() -> None:
    # Fibre widens the plausible range; it does not excuse a nonsense panel.
    source = Foods(
        {
            "cloves": [
                food(
                    fdc_id=171321,
                    calories="10",
                    protein="5.97",
                    carbohydrate="65.53",
                    fat="13.0",
                    fibre="33.9",
                    search_rank=0,
                )
            ]
        }
    )

    records = uncounted_ingredients(
        source,
        ingredient(name="cloves", query="cloves"),
    )

    assert [(value.name, value.code) for value in records] == [
        ("cloves", "inconsistentNutrients")
    ]


def test_an_irrelevant_top_result_loses_to_a_relevant_one_further_down() -> None:
    """USDA's first hit for "cinnamon stick" was APPLEBEE'S mozzarella sticks.

    Nothing checked that a provider-ranked candidate had anything to do with
    the query, so the recipe was costed from it.
    """
    irrelevant = food(
        fdc_id=169011,
        description="APPLEBEE'S, mozzarella sticks",
        data_type="Survey (FNDDS)",
        calories="316",
        search_rank=0,
    )
    relevant = food(
        fdc_id=171329,
        description="Spices, cinnamon, ground",
        data_type="SR Legacy",
        calories="247",
        protein="3.99",
        carbohydrate="80.59",
        fat="1.24",
        fibre="53.1",
        search_rank=1,
    )
    source = Foods({"cinnamon": [irrelevant, relevant]})

    result = NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="cinnamon", query="cinnamon")])
    )

    assert result is not None
    assert "FDC 171329" in (result.evidence or "")


def test_plural_and_singular_count_as_the_same_word() -> None:
    # "seeds" against "Spices, cumin seed" started all of this.
    match = food(
        fdc_id=170923,
        description="Spices, cumin seed",
        data_type="SR Legacy",
        calories="375",
        protein="17.81",
        carbohydrate="44.24",
        fat="22.27",
        fibre="10.5",
        search_rank=0,
    )
    source = Foods({"cumin seeds": [match]})
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="cumin seeds", query="cumin seeds")]),
        uncounted=records,
    )

    assert result is not None
    assert records == []


def test_a_weak_match_is_uncounted_rather_than_costed() -> None:
    """Nothing relevant exists for garam masala, so it is left out.

    Costing a spice blend from `SMART SOUP, Indian Bean Masala` is not an
    imprecise number, it is a wrong one, and a flag beside it does not undo
    that. Dropping the ingredient no longer costs the recipe its calories,
    so there is nothing left to buy by costing a match nothing believes in.
    """
    weak = food(
        fdc_id=171181,
        description="SMART SOUP, Indian Bean Masala",
        data_type="SR Legacy",
        calories="57",
        protein="3",
        carbohydrate="8",
        fat="1",
        search_rank=0,
    )
    source = Foods({"garam masala": [weak]})

    records = uncounted_ingredients(
        source,
        ingredient(name="garam masala", query="garam masala"),
    )

    assert [(value.name, value.code) for value in records] == [
        ("garam masala", "foodNotFound")
    ]


def test_sharing_the_qualifiers_is_not_enough_without_the_food_itself() -> None:
    """ "coriander leaf raw" matched "Lettuce, leaf, green, raw".

    Two of the three words agreed, which was enough under a plain majority.
    The one that disagreed was the only one naming the food.
    """
    lettuce = food(
        fdc_id=169247,
        description="Lettuce, leaf, green, raw",
        data_type="SR Legacy",
        calories="18",
        protein="1.36",
        carbohydrate="3.29",
        fat="0.15",
        fibre="1.3",
        search_rank=0,
    )
    source = Foods({"coriander leaf raw": [lettuce]})

    records = uncounted_ingredients(
        source,
        ingredient(name="coriander", query="coriander leaf raw"),
    )

    assert [value.name for value in records] == ["coriander"]


def test_the_food_word_may_be_qualified_by_the_record() -> None:
    # "Carrots, baby, raw" for "carrot raw" is a good match, not a weak one.
    carrots = food(
        fdc_id=170393,
        description="Carrots, baby, raw",
        data_type="SR Legacy",
        calories="35",
        protein="0.64",
        carbohydrate="8.24",
        fat="0.13",
        fibre="2.9",
        search_rank=0,
    )
    source = Foods({"carrot raw": [carrots]})
    records: list[UncountedIngredient] = []

    NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="carrot", query="carrot raw")]),
        uncounted=records,
    )

    assert records == []


def test_a_contradicted_state_is_uncounted_however_well_the_food_matches() -> None:
    """ "coriander leaf raw" matched "Spices, coriander leaf, dried".

    The food is right and the form is right; only the state disagrees, and
    that is the whole difference between 279 kcal and about 23.
    """
    dried = food(
        fdc_id=170921,
        description="Spices, coriander leaf, dried",
        data_type="SR Legacy",
        calories="279",
        protein="21.93",
        carbohydrate="52.1",
        fat="4.78",
        fibre="10.4",
        search_rank=0,
    )
    source = Foods({"coriander leaf raw": [dried]})

    records = uncounted_ingredients(
        source,
        ingredient(name="coriander", query="coriander leaf raw"),
    )

    assert [(value.name, value.code) for value in records] == [
        ("coriander", "foodNotFound")
    ]


def test_an_agreeing_state_is_not_a_conflict() -> None:
    canned = food(
        fdc_id=170172,
        description="Nuts, coconut milk, canned",
        data_type="SR Legacy",
        calories="197",
        protein="2.02",
        carbohydrate="2.81",
        fat="21.33",
        search_rank=0,
    )
    source = Foods({"coconut milk canned": [canned]})
    records: list[UncountedIngredient] = []

    NutritionCalculator(source).calculate_required(
        recipe([ingredient(name="coconut milk", query="coconut milk canned")]),
        uncounted=records,
    )

    assert records == []


def test_one_unmatched_ingredient_of_many_still_totals_the_rest() -> None:
    """The reversal this issue is for.

    A curry does not lose every calorie because USDA has no row for curry
    leaves. The leaves drop out, the record says so, and the rest is costed.
    """
    source = Foods(
        {
            "chicken thigh raw": [
                food(
                    fdc_id=171077,
                    description="Chicken, thigh, raw",
                    data_type="SR Legacy",
                    calories="209",
                    protein="17.27",
                    carbohydrate="0",
                    fat="15.25",
                    search_rank=0,
                )
            ]
        }
    )
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(source).calculate_required(
        recipe(
            [
                ingredient(
                    name="chicken thighs",
                    query="chicken thigh raw",
                    quantity="500",
                    metric_amount="500",
                ),
                ingredient(
                    name="curry leaves",
                    query="curry leaves",
                    quantity="5",
                    metric_amount="5",
                    order_index=1,
                ),
            ],
            servings="4",
        ),
        uncounted=records,
    )

    assert result.calories == Decimal("261.3")
    assert [value.name for value in records] == ["curry leaves"]
    assert result.evidence == "USDA FDC 171077"


def test_uncounted_mass_over_the_share_blocks_the_recipe() -> None:
    """Skipping the chicken is not the same as skipping the curry leaves.

    The floor is on mass, not on how many ingredients failed: a quarter of
    the dish going uncounted is the point at which the remaining number
    stops describing the plate.
    """
    source = Foods(
        {
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ]
        }
    )
    records: list[UncountedIngredient] = []

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(source).calculate_required(
            recipe(
                [
                    ingredient(
                        name="egg noodles",
                        query="egg noodles dry",
                        quantity="300",
                        metric_amount="300",
                    ),
                    ingredient(
                        name="garam masala",
                        query="garam masala",
                        quantity="200",
                        metric_amount="200",
                        order_index=1,
                    ),
                ]
            ),
            uncounted=records,
        )

    assert error.value.code == "insufficientCoverage"
    assert [value.name for value in records] == ["garam masala"]


def test_uncounted_mass_at_the_share_is_still_costed() -> None:
    # 100 g of 500 g is exactly the default quarter; the floor is a strict
    # inequality, so the boundary is costed rather than blocked.
    source = Foods(
        {
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ]
        }
    )
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(source).calculate_required(
        recipe(
            [
                ingredient(
                    name="egg noodles",
                    query="egg noodles dry",
                    quantity="400",
                    metric_amount="400",
                ),
                ingredient(
                    name="garam masala",
                    query="garam masala",
                    quantity="100",
                    metric_amount="100",
                    order_index=1,
                ),
            ]
        ),
        uncounted=records,
    )

    assert result.calories == Decimal("140.0")
    assert [value.estimated_grams for value in records] == [Decimal("100")]


def test_a_stricter_share_blocks_what_the_default_allows() -> None:
    source = Foods(
        {
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ]
        }
    )
    template = recipe(
        [
            ingredient(
                name="egg noodles",
                query="egg noodles dry",
                quantity="400",
                metric_amount="400",
            ),
            ingredient(
                name="garam masala",
                query="garam masala",
                quantity="100",
                metric_amount="100",
                order_index=1,
            ),
        ]
    )

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(
            source,
            uncounted_mass_share_limit=Decimal("0.1"),
        ).calculate_required(template)

    assert error.value.code == "insufficientCoverage"


def test_the_fallback_source_is_consulted_once_and_costed() -> None:
    """USDA answers what it can; the second provider is asked about the rest.

    The provider seam is the point: one search per ingredient in the common
    case, and a second only where the first came back with nothing usable.
    """
    usda = Foods(
        {
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ]
        }
    )
    fallback = Foods(
        {
            "garam masala": [
                food(
                    fdc_id=9001,
                    description="garam masala",
                    calories="379",
                    protein="14",
                    carbohydrate="45",
                    fat="15",
                    fibre="21",
                    search_rank=0,
                )
            ]
        },
        name="Fake Foods",
    )
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(usda, fallback).calculate_required(
        recipe(
            [
                ingredient(
                    name="egg noodles",
                    query="egg noodles dry",
                    quantity="400",
                    metric_amount="400",
                ),
                ingredient(
                    name="garam masala",
                    query="garam masala",
                    quantity="100",
                    metric_amount="100",
                    order_index=1,
                ),
            ]
        ),
        uncounted=records,
    )

    assert records == []
    # Only the ingredient USDA could not answer reaches the fallback.
    assert fallback.calls == ["garam masala"]
    assert result.evidence == "USDA FDC 23, Fake Foods 9001"


def test_a_weak_match_reaches_the_fallback_before_being_dropped() -> None:
    """Beef curry for curry leaves is not an answer, so the ladder continues.

    Treating a weak match as unmatched is only defensible if it goes through
    the same rungs as anything else that failed.
    """
    usda = Foods(
        {
            "curry leaves": [
                food(
                    fdc_id=170691,
                    description="Beef curry",
                    data_type="Survey (FNDDS)",
                    calories="150",
                    protein="10",
                    carbohydrate="5",
                    fat="10",
                    search_rank=0,
                )
            ]
        }
    )
    fallback = Foods(
        {
            "curry leaves": [
                food(
                    fdc_id=9002,
                    description="curry leaves raw",
                    calories="108",
                    protein="6",
                    carbohydrate="18",
                    fat="1",
                    fibre="6",
                    search_rank=0,
                )
            ]
        },
        name="Fake Foods",
    )
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(usda, fallback).calculate_required(
        recipe([ingredient(name="curry leaves", query="curry leaves")]),
        uncounted=records,
    )

    assert records == []
    assert fallback.calls == ["curry leaves"]
    assert result.evidence == "Fake Foods 9002"


def test_a_fallback_that_also_fails_leaves_the_ingredient_uncounted() -> None:
    usda = Foods(
        {
            "egg noodles dry": [
                food(fdc_id=23, description="egg noodles dry", search_rank=0)
            ]
        }
    )
    fallback = Foods({}, name="Fake Foods")
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(usda, fallback).calculate_required(
        recipe(
            [
                ingredient(
                    name="egg noodles",
                    query="egg noodles dry",
                    quantity="400",
                    metric_amount="400",
                ),
                ingredient(
                    name="curry leaves",
                    query="curry leaves",
                    quantity="5",
                    metric_amount="5",
                    order_index=1,
                ),
            ]
        ),
        uncounted=records,
    )

    assert [value.name for value in records] == ["curry leaves"]
    assert fallback.calls == ["curry leaves"]
    assert result.evidence == "USDA FDC 23"


def test_an_unusable_yield_is_still_a_whole_recipe_failure() -> None:
    # Degrading per ingredient does not make every failure per ingredient:
    # without a serving count there is nothing to divide by.
    source = Foods({"chickpeas drained": [food()]})

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(source).calculate_required(
            recipe([ingredient()], servings_basis="unknown")
        )

    assert error.value.code == "invalidYield"


def test_the_shared_fallback_fake_answers_the_known_usda_gaps() -> None:
    """The fake stands in for the provider PR B will add.

    It exists so the ladder can be exercised without a key, and it answers
    the four ingredients the live library found USDA has no usable row for.
    """
    usda = Foods(
        {
            "chicken thigh raw": [
                food(
                    fdc_id=171077,
                    description="Chicken, thigh, raw",
                    data_type="SR Legacy",
                    calories="209",
                    protein="17.27",
                    carbohydrate="0",
                    fat="15.25",
                    search_rank=0,
                )
            ]
        }
    )
    fallback = FakeFoodDataSource()
    records: list[UncountedIngredient] = []

    result = NutritionCalculator(usda, fallback).calculate_required(
        recipe(
            [
                ingredient(
                    name="chicken thighs",
                    query="chicken thigh raw",
                    quantity="500",
                    metric_amount="500",
                ),
                ingredient(
                    name="curry leaves",
                    query="curry leaves",
                    quantity="5",
                    metric_amount="5",
                    order_index=1,
                ),
            ]
        ),
        uncounted=records,
    )

    assert records == []
    assert result.evidence == "USDA FDC 171077, Fake Foods 900002"
