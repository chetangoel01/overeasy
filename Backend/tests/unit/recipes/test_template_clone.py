from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from ladle.contracts.recipes import RecipeDTO, RecipeSource
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
)


def template(*, notes: list[str]) -> RecipeTemplate:
    return RecipeTemplate(
        title="Lemon Orzo",
        description="Bright and weeknight friendly.",
        creator_name="Cook",
        source=RecipeSource.TIKTOK,
        original_url="https://www.tiktok.com/@cook/video/1234567890",
        preparation_minutes=5,
        cooking_minutes=10,
        total_minutes=15,
        servings=Decimal("2"),
        servings_basis="stated",
        ingredients=[
            TemplateIngredient(
                quantity_text="2 cups",
                normalized_quantity=Decimal("2"),
                unit="cup",
                name="orzo",
                preparation=None,
                order_index=0,
                uncertainty=None,
            )
        ],
        steps=[],
        nutrition=None,
        notes=notes,
        review_status="ready",
        uncertainties=[],
    )


def test_instantiate_carries_the_extracted_notes_onto_the_recipe() -> None:
    notes = ["Toast the orzo first.", "Leftovers keep for three days."]
    source = template(notes=notes)

    recipe = source.instantiate(
        recipe_id=uuid4(),
        now=datetime(2026, 8, 27, 12, 0, tzinfo=UTC),
    )

    assert recipe.notes == notes


def test_from_recipe_keeps_notes_when_a_stored_recipe_is_re_templated() -> None:
    recipe = template(notes=["Toast the orzo first."]).instantiate(
        recipe_id=uuid4(),
        now=datetime(2026, 8, 27, 12, 0, tzinfo=UTC),
    )

    round_tripped = RecipeTemplate.from_recipe(recipe)

    assert round_tripped.notes == ["Toast the orzo first."]


def test_the_approximate_marker_survives_a_round_trip_through_a_recipe() -> None:
    """A partial total stays labelled once it has been stored and read back.

    Re-templating a stored recipe is how re-import and the refresh script
    both start. Losing the marker there would quietly promote an incomplete
    number to a complete one.
    """
    source = template(notes=[]).model_copy(
        update={
            "nutrition": TemplateNutrition(
                calories=Decimal("410"),
                serving_basis=Decimal("1"),
                is_estimated=True,
                approximate=True,
                basis="usdaCalculated",
            )
        }
    )

    recipe = source.instantiate(
        recipe_id=uuid4(),
        now=datetime(2026, 9, 7, 12, 0, tzinfo=UTC),
    )

    assert recipe.nutrition is not None
    assert recipe.nutrition.approximate
    round_tripped = RecipeTemplate.from_recipe(recipe)
    assert round_tripped.nutrition is not None
    assert round_tripped.nutrition.approximate


def test_instantiate_drops_notes_a_recipe_could_never_hold() -> None:
    """A recipe caps notes at 100 entries of 2,000 characters.

    Templates keep whatever extraction produced so already-cached entries stay
    loadable, so the overflow has to be dropped here rather than failing the
    import with a validation error.
    """
    source = template(
        notes=["  ", "x" * 2_500] + [f"note {index}" for index in range(150)]
    )

    recipe = source.instantiate(
        recipe_id=uuid4(),
        now=datetime(2026, 8, 27, 12, 0, tzinfo=UTC),
    )

    assert len(recipe.notes) == 100
    assert recipe.notes[0] == "x" * 2_000
    assert recipe.notes[1] == "note 0"


def strict_template(*ingredients: TemplateIngredient) -> RecipeTemplate:
    return RecipeTemplate(
        title="Lemon Orzo",
        description="Bright and weeknight friendly.",
        creator_name="Cook",
        source=RecipeSource.TIKTOK,
        original_url="https://www.tiktok.com/@cook/video/1234567890",
        servings=Decimal("2"),
        ingredients=list(ingredients),
        steps=[],
        review_status="ready",
    )


def instantiate(*ingredients: TemplateIngredient) -> RecipeDTO:
    return strict_template(*ingredients).instantiate(
        recipe_id=uuid4(),
        now=datetime(2026, 9, 8, 12, 0, tzinfo=UTC),
    )


def test_an_import_lands_with_the_split_left_inside_the_phrase() -> None:
    """The first write point: extraction's template becoming a recipe.

    A model that wrote only "2 cups" used to store a row with no number at
    all, which the app can no longer render.
    """

    recipe = instantiate(
        TemplateIngredient(quantity_text="2 cups", name="orzo", order_index=0)
    )

    assert recipe.ingredients[0].normalized_quantity == Decimal("2")
    assert recipe.ingredients[0].unit == "cups"
    assert recipe.ingredients[0].is_to_taste is False


def test_an_import_with_nothing_to_parse_says_it_has_no_quantity() -> None:
    recipe = instantiate(
        TemplateIngredient(
            quantity_text="a splash",
            name="olive oil",
            order_index=0,
        )
    )

    assert recipe.ingredients[0].is_to_taste is True
    assert recipe.ingredients[0].normalized_quantity is None
    # The phrase survives as the note it is.
    assert recipe.ingredients[0].quantity_text == "a splash"


def test_the_extractions_own_to_taste_answer_reaches_the_recipe() -> None:
    recipe = instantiate(
        TemplateIngredient(name="flaky salt", is_to_taste=True, order_index=0)
    )

    assert recipe.ingredients[0].is_to_taste is True


def test_re_templating_a_stored_recipe_keeps_its_missing_quantity() -> None:
    """`from_recipe` hardcoded False, losing the answer on every clone."""

    recipe = instantiate(
        TemplateIngredient(name="flaky salt", is_to_taste=True, order_index=0)
    )

    assert RecipeTemplate.from_recipe(recipe).ingredients[0].is_to_taste is True
