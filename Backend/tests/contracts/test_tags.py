"""The three tag vocabularies, and what a recipe is allowed to carry."""

from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID

import pytest
from pydantic import ValidationError

from ladle.contracts.recipes import (
    RecipeDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.contracts.tags import (
    MAX_KEYWORD_PROPOSALS,
    CuisineTag,
    DietTag,
    RecipeKeyword,
    coerce_tags,
    normalize_proposal,
    split_keywords,
)

RECIPE_ID = UUID("20000000-0000-4000-8000-000000000001")
NOW = datetime(2026, 9, 7, 12, tzinfo=UTC)


def recipe(**overrides: object) -> RecipeDTO:
    values: dict[str, object] = {
        "id": RECIPE_ID,
        "title": "Lemon Orzo",
        "description": "",
        "source": RecipeSource.TIKTOK,
        "original_url": "https://www.tiktok.com/@mia/video/1",
        "servings": Decimal("4"),
        "is_favorite": False,
        "review_status": RecipeReviewStatus.READY,
        "revision": 1,
        "created_at": NOW,
        "updated_at": NOW,
    }
    values.update(overrides)
    return RecipeDTO.model_validate(values)


def test_vocabularies_are_the_sizes_the_brief_proposed() -> None:
    assert len(DietTag) == 5
    assert len(CuisineTag) == 15
    assert len(RecipeKeyword) == 25


def test_coerce_tags_drops_values_that_are_not_in_the_closed_list() -> None:
    assert coerce_tags(DietTag, ["vegan", "keto", "vegetarian"]) == [
        DietTag.VEGETARIAN,
        DietTag.VEGAN,
    ]


def test_coerce_tags_accepts_the_spelling_a_model_actually_writes() -> None:
    assert coerce_tags(DietTag, ["Gluten-Free", "dairy free"]) == [
        DietTag.GLUTEN_FREE,
        DietTag.DAIRY_FREE,
    ]
    assert coerce_tags(CuisineTag, ["Middle Eastern"]) == [CuisineTag.MIDDLE_EASTERN]


def test_coerce_tags_deduplicates_and_orders_by_the_declared_vocabulary() -> None:
    assert coerce_tags(DietTag, ["vegan", "vegan", "vegetarian"]) == [
        DietTag.VEGETARIAN,
        DietTag.VEGAN,
    ]


def test_split_keywords_keeps_proposals_out_of_the_canonical_set() -> None:
    canonical, proposals = split_keywords(
        ["one-pot", "freezer friendly", "picnic", "student budget"]
    )

    assert canonical == [RecipeKeyword.ONE_POT, RecipeKeyword.FREEZER_FRIENDLY]
    assert proposals == ["picnic", "student-budget"]


def test_split_keywords_caps_and_deduplicates_proposals() -> None:
    offered = ["picnic", "PICNIC", *(f"term-{index}" for index in range(20))]
    _, proposals = split_keywords(offered)

    assert proposals[0] == "picnic"
    assert len(proposals) == MAX_KEYWORD_PROPOSALS
    assert len(set(proposals)) == len(proposals)


def test_normalize_proposal_rejects_text_that_is_not_a_tag() -> None:
    assert normalize_proposal("  Sheet   Pan  ") == "sheet-pan"
    assert normalize_proposal("!!!") is None
    assert normalize_proposal("") is None


def test_recipe_carries_the_three_families_and_the_proposals() -> None:
    value = recipe(
        diets=[DietTag.VEGETARIAN, DietTag.GLUTEN_FREE],
        cuisines=[CuisineTag.ITALIAN],
        keywords=[RecipeKeyword.ONE_POT],
        keyword_proposals=["picnic"],
    )

    assert value.diets == [DietTag.VEGETARIAN, DietTag.GLUTEN_FREE]
    assert value.cuisines == [CuisineTag.ITALIAN]
    assert value.keywords == [RecipeKeyword.ONE_POT]
    assert value.keyword_proposals == ["picnic"]


def test_absent_tags_are_none_rather_than_empty() -> None:
    """An old build encodes no tag keys at all; that must not read as "clear"."""

    value = recipe()

    assert value.diets is None
    assert value.cuisines is None
    assert value.keywords is None
    assert value.keyword_proposals is None


def test_recipe_rejects_a_diet_outside_the_enum() -> None:
    with pytest.raises(ValidationError):
        recipe(diets=["keto"])


def test_recipe_rejects_a_cuisine_outside_the_enum() -> None:
    with pytest.raises(ValidationError):
        recipe(cuisines=["martian"])


def test_recipe_rejects_repeated_tags() -> None:
    """The tag tables are keyed on the value; a repeat would be a 500."""

    with pytest.raises(ValidationError):
        recipe(diets=[DietTag.VEGAN, DietTag.VEGAN])
    with pytest.raises(ValidationError):
        recipe(keyword_proposals=["picnic", "picnic"])
