from dataclasses import dataclass, field
from decimal import Decimal

import pytest

from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.nutrition.calculator import (
    NutritionCalculationUnavailable,
    NutritionCalculator,
)
from ladle.nutrition.usda import FoodNutrients, FoodPortion
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
)


@dataclass
class Foods:
    values: dict[str, list[FoodNutrients]]
    calls: list[str] = field(default_factory=list)

    def candidates(self, query: str) -> list[FoodNutrients]:
        self.calls.append(query)
        return self.values.get(query, [])


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

    result = NutritionCalculator(source).calculate(
        recipe([value], servings="4")
    )

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
        {
            "chickpeas drained": [
                food(portions=[portion("ml", "103", amount="100")])
            ]
        }
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

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(source).calculate_required(recipe([value]))

    assert error.value.code == "ambiguousFoodMatch"
    assert error.value.ingredient_index == 0
    assert error.value.ingredient_name == "rice"


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
        calculator.calculate_required(
            recipe([ingredient()], servings_basis="unknown")
        )

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


def test_missing_food_match_returns_no_nutrition() -> None:
    assert NutritionCalculator(Foods({})).calculate(recipe([ingredient()])) is None

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(Foods({})).calculate_required(recipe([ingredient()]))

    assert error.value.code == "foodNotFound"
    assert error.value.ingredient_index == 0
    assert error.value.ingredient_name == "chickpeas"


def test_gross_calorie_macro_inconsistency_is_rejected() -> None:
    inconsistent = food(calories="900", protein="1", carbohydrate="1", fat="1")
    source = Foods({"chickpeas drained": [inconsistent]})

    assert NutritionCalculator(source).calculate(recipe([ingredient()])) is None

    with pytest.raises(NutritionCalculationUnavailable) as error:
        NutritionCalculator(source).calculate_required(recipe([ingredient()]))

    assert error.value.code == "inconsistentNutrients"
    assert error.value.ingredient_index == 0


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
    calculator = NutritionCalculator(Foods({"chickpeas drained": [food()]}))

    with pytest.raises(NutritionCalculationUnavailable) as error:
        calculator.calculate_required(recipe([value]))

    assert error.value.code == "missingMass"
    assert error.value.ingredient_index == 0
    assert error.value.ingredient_name == "chickpeas"
