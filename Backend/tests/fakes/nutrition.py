"""Deterministic food sources for the nutrition ladder.

`FakeFoodDataSource` stands in for the second provider PR B will add: it
answers from a fixed table, records what it was asked, and never touches the
network, so a test can prove the fallback rung is reached without a key.
"""

from dataclasses import dataclass, field
from decimal import Decimal

from ladle.nutrition.usda import FoodNutrients

#: Composite and regional ingredients USDA has no usable row for. These are
#: the four gaps the September 1 dry run found, which are the ones a second
#: provider exists to answer.
FALLBACK_FOODS: dict[str, FoodNutrients] = {
    query: FoodNutrients(
        fdc_id=fdc_id,
        description=description,
        data_type="SR Legacy",
        calories_per_100g=Decimal(calories),
        protein_grams_per_100g=Decimal(protein),
        carbohydrate_grams_per_100g=Decimal(carbohydrate),
        fat_grams_per_100g=Decimal(fat),
        fibre_grams_per_100g=Decimal(fibre),
        search_rank=0,
    )
    for query, fdc_id, description, calories, protein, carbohydrate, fat, fibre in (
        ("garam masala", 900001, "garam masala", "379", "14", "45", "15", "21"),
        ("curry leaves", 900002, "curry leaves raw", "108", "6", "18", "1", "6"),
        (
            "ginger garlic paste",
            900003,
            "ginger garlic paste",
            "110",
            "4",
            "22",
            "1",
            "2",
        ),
        ("tamarind", 900004, "tamarind raw", "239", "2", "62", "1", "5"),
    )
}


@dataclass
class FakeFoodDataSource:
    """A `FoodDataSource` that answers from a fixed table."""

    values: dict[str, FoodNutrients] = field(
        default_factory=lambda: dict(FALLBACK_FOODS)
    )
    calls: list[str] = field(default_factory=list)
    name: str = "Fake Foods"

    def candidates(self, query: str) -> list[FoodNutrients]:
        self.calls.append(query)
        match = self.values.get(query.strip().casefold())
        return [match] if match is not None else []
