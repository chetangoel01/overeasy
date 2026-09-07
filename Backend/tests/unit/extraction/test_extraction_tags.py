"""Tags from the model, through review, onto the template a cook is given."""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import uuid4

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor
from ladle.contracts.tags import CuisineTag, DietTag, RecipeKeyword
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedStep,
    RecipeExtraction,
)
from ladle.extraction.prompt import SYSTEM_PROMPT
from ladle.extraction.review import build_reviewed_template


def context() -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="tag-test",
            canonical_url="https://www.tiktok.com/@cook/video/1234567890",
            source_revision="1",
        ),
        is_public=True,
        title="Recipe",
        description="",
        transcript=[],
        visual_observations=[],
        diagnostics=[],
    )


def extraction(**overrides: object) -> RecipeExtraction:
    values: dict[str, object] = {
        "title": "Lemon Orzo",
        "description": "",
        "servings": Decimal("4"),
        "ingredients": [
            ExtractedIngredient(
                name="orzo",
                quantity_text="2 cups",
                normalized_quantity=Decimal("2"),
                unit="cup",
                confidence=0.95,
            )
        ],
        "steps": [
            ExtractedStep(
                instruction="Cook the orzo.",
                ingredient_indices=[0],
                confidence=0.95,
            )
        ],
    }
    values.update(overrides)
    return RecipeExtraction.model_validate(values)


def test_extraction_parses_the_three_families() -> None:
    parsed = extraction(
        diets=["vegetarian", "Gluten-Free"],
        cuisines=["Middle Eastern"],
        keywords=["one-pot", "weeknight"],
    )

    assert parsed.diets == [DietTag.VEGETARIAN, DietTag.GLUTEN_FREE]
    assert parsed.cuisines == [CuisineTag.MIDDLE_EASTERN]
    assert parsed.keywords == ["one-pot", "weeknight"]


def test_extraction_drops_a_diet_or_cuisine_that_is_not_on_the_list() -> None:
    """One invented tag must never cost the whole recipe."""

    parsed = extraction(
        diets=["keto", "vegan"],
        cuisines=["martian", "italian"],
    )

    assert parsed.diets == [DietTag.VEGAN]
    assert parsed.cuisines == [CuisineTag.ITALIAN]
    assert parsed.ingredients[0].name == "orzo"


def test_extraction_defaults_to_no_tags_at_all() -> None:
    """Templates cached before tags existed still have to load."""

    parsed = extraction()

    assert parsed.diets == []
    assert parsed.cuisines == []
    assert parsed.keywords == []


def test_review_keeps_a_proposed_keyword_out_of_the_canonical_set() -> None:
    template = build_reviewed_template(
        extraction(
            diets=["vegetarian"],
            cuisines=["italian"],
            keywords=["one-pot", "picnic food", "weeknight"],
        ),
        context=context(),
    )

    assert template.diets == [DietTag.VEGETARIAN]
    assert template.cuisines == [CuisineTag.ITALIAN]
    assert template.keywords == [RecipeKeyword.ONE_POT, RecipeKeyword.WEEKNIGHT]
    assert template.keyword_proposals == ["picnic-food"]


def test_review_leaves_an_untagged_extraction_with_empty_families() -> None:
    template = build_reviewed_template(extraction(), context=context())

    assert template.diets == []
    assert template.cuisines == []
    assert template.keywords == []
    assert template.keyword_proposals == []


def test_template_tags_survive_instantiation_into_a_recipe() -> None:
    template = build_reviewed_template(
        extraction(
            diets=["vegan"],
            cuisines=["japanese"],
            keywords=["meal prep", "izakaya"],
        ),
        context=context(),
    )

    recipe = template.instantiate(
        recipe_id=uuid4(), now=datetime(2026, 9, 7, tzinfo=UTC)
    )

    assert recipe.diets == [DietTag.VEGAN]
    assert recipe.cuisines == [CuisineTag.JAPANESE]
    assert recipe.keywords == [RecipeKeyword.MEAL_PREP]
    assert recipe.keyword_proposals == ["izakaya"]


def test_prompt_names_every_value_in_all_three_vocabularies() -> None:
    """The prompt is rendered from the enums; nothing may go unmentioned."""

    for vocabulary in (DietTag, CuisineTag, RecipeKeyword):
        for member in vocabulary:
            assert member.value in SYSTEM_PROMPT, member
