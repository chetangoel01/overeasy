"""Which foods nutrition keeps failing to count, read for the operator.

`nutrition_skips` holds one row per ingredient a recipe could not cost. The
cook is told about their own recipe in prose on the ingredient row; this is
the other reading of the same rows — the same food across the whole corpus,
which is the backlog the curated table of issue #37 is grown from.

The names come back exactly as the pipeline recorded them. A trimmed or
title-cased name here would not be the string the calculator asked USDA for,
and the table seeded from this panel has to answer that string.
"""

from dataclasses import dataclass
from decimal import Decimal
from uuid import UUID

from sqlalchemy import ColumnElement, Select, func, select
from sqlalchemy.orm import Session

from ladle.db.models import NutritionSkip, Recipe

#: How many distinct names the panel asks for, and how many recipes it names
#: under each. The aggregate has to read every live skip row to rank names by
#: frequency, but what crosses the wire and what the browser lays out stay
#: fixed as the corpus grows.
NAME_LIMIT = 25
EXAMPLE_LIMIT = 3


@dataclass(frozen=True)
class MissedRecipe:
    """One recipe a name was skipped on. There is no page to link to."""

    id: UUID
    title: str


@dataclass(frozen=True)
class MissedName:
    name: str
    skips: int
    recipes: int
    estimated_grams: Decimal | None
    codes: list[tuple[str, int]]
    examples: list[MissedRecipe]


@dataclass(frozen=True)
class NutritionMisses:
    names: list[MissedName]
    total_names: int
    total_skips: int
    total_recipes: int


def _live() -> ColumnElement[bool]:
    """API deletion is soft.

    Without this the recipes a cook threw away go on voting for a food, and
    the head of the backlog is a queue of work nobody wants done.
    """

    return Recipe.deleted_at.is_(None)


def summarise_misses(
    database: Session,
    *,
    name_limit: int = NAME_LIMIT,
    example_limit: int = EXAMPLE_LIMIT,
) -> NutritionMisses:
    totals = database.execute(
        select(
            func.count(func.distinct(NutritionSkip.ingredient_name)),
            func.count(),
            func.count(func.distinct(NutritionSkip.recipe_id)),
        )
        .select_from(NutritionSkip)
        .join(Recipe, Recipe.id == NutritionSkip.recipe_id)
        .where(_live())
    ).one()

    ranked = database.execute(
        select(
            NutritionSkip.ingredient_name,
            func.count().label("skips"),
            func.count(func.distinct(NutritionSkip.recipe_id)).label("recipes"),
            func.sum(NutritionSkip.estimated_grams).label("grams"),
        )
        .join(Recipe, Recipe.id == NutritionSkip.recipe_id)
        .where(_live())
        .group_by(NutritionSkip.ingredient_name)
        # The name breaks the tie, so a reload does not reshuffle the middle
        # of the list under the operator.
        .order_by(func.count().desc(), NutritionSkip.ingredient_name)
        .limit(name_limit)
    ).all()
    names = [row.ingredient_name for row in ranked]
    if not names:
        return NutritionMisses(
            names=[],
            total_names=totals[0],
            total_skips=totals[1],
            total_recipes=totals[2],
        )

    codes: dict[str, list[tuple[str, int]]] = {name: [] for name in names}
    for row in database.execute(
        select(NutritionSkip.ingredient_name, NutritionSkip.code, func.count())
        .join(Recipe, Recipe.id == NutritionSkip.recipe_id)
        .where(_live(), NutritionSkip.ingredient_name.in_(names))
        .group_by(NutritionSkip.ingredient_name, NutritionSkip.code)
        .order_by(func.count().desc(), NutritionSkip.code)
    ):
        codes[row[0]].append((row[1], row[2]))

    examples: dict[str, list[MissedRecipe]] = {name: [] for name in names}
    for example in database.execute(_examples(names, limit=example_limit)):
        examples[example.name].append(
            MissedRecipe(id=example.recipe_id, title=example.title)
        )

    return NutritionMisses(
        names=[
            MissedName(
                name=row.ingredient_name,
                skips=row.skips,
                recipes=row.recipes,
                estimated_grams=row.grams,
                codes=codes[row.ingredient_name],
                examples=examples[row.ingredient_name],
            )
            for row in ranked
        ],
        total_names=totals[0],
        total_skips=totals[1],
        total_recipes=totals[2],
    )


def _examples(names: list[str], *, limit: int) -> Select[tuple[str, UUID, str]]:
    """The most recently skipped recipes per name, ranked in the database.

    A window function rather than one query per name: the number of rows read
    stays proportional to the misses on these names, and the number returned
    is `len(names) * limit` whatever the corpus does.
    """

    rank = (
        func.row_number()
        .over(
            partition_by=NutritionSkip.ingredient_name,
            # `recorded_at` is the transaction clock, so a batch of skips
            # written together shares one timestamp; the title and the id
            # settle it rather than leaving the sample to the planner.
            order_by=(
                NutritionSkip.recorded_at.desc(),
                Recipe.title,
                Recipe.id,
            ),
        )
        .label("rank")
    )
    ranked = (
        select(
            NutritionSkip.ingredient_name.label("name"),
            Recipe.id.label("recipe_id"),
            Recipe.title.label("title"),
            rank,
        )
        .join(Recipe, Recipe.id == NutritionSkip.recipe_id)
        .where(_live(), NutritionSkip.ingredient_name.in_(names))
        .subquery()
    )
    return (
        select(ranked.c.name, ranked.c.recipe_id, ranked.c.title)
        .where(ranked.c.rank <= limit)
        .order_by(ranked.c.name, ranked.c.rank)
    )
