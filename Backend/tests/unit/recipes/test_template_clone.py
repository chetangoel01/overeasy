from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from ladle.contracts.recipes import RecipeSource
from ladle.recipes.template_clone import RecipeTemplate, TemplateIngredient


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
