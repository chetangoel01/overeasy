"""A checked-in table of foods USDA has no usable record for.

The ladder USDA sits on skips whatever it cannot cost, which is honest but
leaves a cook short a spice on every South Asian recipe in the library. The
table closes the gaps one row at a time: values estimated per 100 g, each
row stating how its numbers were reached, and every row read by a human in
a diff before it merged. That review is the only safeguard there is, which
is why the basis is stored beside the numbers rather than in a commit
message nobody re-reads.

Matching is deliberately dumb. An entry answers to its own name and to an
explicit list of aliases, compared on lowercase alphanumeric words and
nothing else. Nothing is fuzzy: a table that guesses would be a second
matching layer to debug, and the whole reason these foods are here is that
the first one guessed wrong.
"""

import re
from collections.abc import Sequence
from functools import cache
from pathlib import Path

from pydantic import Field

from ladle.contracts.common import WireDecimal, WireModel
from ladle.nutrition.usda import FoodNutrients, FoodPortion

_TABLE = Path(__file__).with_name("curated_foods.json")

#: Curated identifiers start here. They are not FoodData Central ids and
#: never reach a screen — the evidence line names the source and the food —
#: but `FoodNutrients` needs one, and a block far above USDA's range cannot
#: be mistaken for a real record if it ever shows up in a log.
CURATED_ID_FLOOR = 9_000_000


class CuratedFood(WireModel):
    """One reviewed estimate, per 100 g."""

    id: int = Field(gt=CURATED_ID_FLOOR)
    name: str = Field(min_length=1)
    #: Spellings a recipe might use for this food. The canonical name is
    #: always matched too and does not need repeating here.
    aliases: list[str] = Field(min_length=1)
    #: How the numbers were reached, in enough detail to be checked: the
    #: USDA records averaged, the assumption made, or the admission that a
    #: figure is a guess.
    basis: str = Field(min_length=1)
    calories_per_100g: WireDecimal = Field(ge=0)
    protein_grams_per_100g: WireDecimal = Field(ge=0)
    carbohydrate_grams_per_100g: WireDecimal = Field(ge=0)
    fat_grams_per_100g: WireDecimal = Field(ge=0)
    #: Required here, unlike USDA's records where it is genuinely unknown.
    #: The consistency band is wider when fibre is known, and an estimate
    #: with no fibre figure would be checked against the wrong band.
    fibre_grams_per_100g: WireDecimal = Field(ge=0)
    #: What "1 tsp" weighs. Needed whenever the normalizer could not put a
    #: gram figure on the ingredient itself.
    portions: list[FoodPortion] = Field(default_factory=list)

    def nutrients(self) -> FoodNutrients:
        """The same shape a provider answers with, so nothing downstream cares."""
        return FoodNutrients(
            fdc_id=self.id,
            description=self.name,
            data_type="Curated",
            calories_per_100g=self.calories_per_100g,
            protein_grams_per_100g=self.protein_grams_per_100g,
            carbohydrate_grams_per_100g=self.carbohydrate_grams_per_100g,
            fat_grams_per_100g=self.fat_grams_per_100g,
            fibre_grams_per_100g=self.fibre_grams_per_100g,
            portions=self.portions,
        )


class _CuratedFile(WireModel):
    #: Prose at the top of the data file, addressed to whoever adds a row.
    comment: list[str] = Field(default_factory=list)
    entries: list[CuratedFood]


class CuratedFoodTable:
    """The table, indexed by every name its entries answer to."""

    name = "Ladle curated"

    def __init__(self, entries: Sequence[CuratedFood]) -> None:
        index: dict[str, CuratedFood] = {}
        for entry in entries:
            for alias in (entry.name, *entry.aliases):
                key = _key(alias)
                if not key:
                    raise ValueError(f"{entry.name} has an empty alias")
                claimed = index.get(key)
                if claimed is not None and claimed is not entry:
                    raise ValueError(
                        f"{claimed.name} and {entry.name} both answer to {key}"
                    )
                index[key] = entry
        self._entries = tuple(entries)
        self._index = index

    @property
    def entries(self) -> tuple[CuratedFood, ...]:
        return self._entries

    def lookup(self, *names: str | None) -> FoodNutrients | None:
        """The first of `names` the table has an entry for.

        More than one name is accepted because an ingredient carries two:
        what the cook wrote, and the descriptor the normalizer rewrote it
        into for USDA. The table is keyed to the first — it is the field no
        model rewrites — and the second is only tried when the first misses.
        """
        for name in names:
            entry = self._index.get(_key(name)) if name else None
            if entry is not None:
                return entry.nutrients()
        return None


def _key(value: str) -> str:
    return " ".join(re.findall(r"[a-z0-9]+", value.casefold()))


@cache
def curated_food_table() -> CuratedFoodTable:
    """The shipped table, parsed once per process."""
    parsed = _CuratedFile.model_validate_json(_TABLE.read_text(encoding="utf-8"))
    return CuratedFoodTable(parsed.entries)
