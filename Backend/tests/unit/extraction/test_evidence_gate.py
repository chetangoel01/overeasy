from uuid import uuid4

import pytest

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)
from ladle.contracts.imports import ImportFailure
from ladle.extraction.evidence_gate import (
    InsufficientTextEvidence,
    require_recipe_evidence,
)


def _context(
    *,
    title: str | None = "Recipe",
    description: str = "",
    transcript: str | None = None,
    linked_document: str | None = None,
    platform_text: str | None = None,
) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="instagram",
            platform_video_id="evidence-gate",
            canonical_url="https://www.instagram.com/reel/evidence-gate",
            source_revision="1",
        ),
        is_public=True,
        title=title,
        description=description,
        transcript=(
            [
                TextEvidence(
                    text=transcript,
                    provenance="instagram:native",
                    generated=False,
                )
            ]
            if transcript
            else []
        ),
        linked_documents=(
            [
                LinkedDocument(
                    url="https://creator.example/recipe",
                    text=linked_document,
                    provenance="creatorPage",
                )
            ]
            if linked_document
            else []
        ),
        visual_observations=(
            [
                VisualEvidence(
                    text=platform_text,
                    provenance="tiktok:sticker",
                )
            ]
            if platform_text
            else []
        ),
    )


@pytest.mark.parametrize(
    "context",
    [
        _context(title="Creamy Garlic Pasta"),
        _context(
            description=(
                "The coziest dinner! Add 2 cups pasta and simmer tonight. "
                "Full recipe in bio."
            )
        ),
        _context(transcript="Chickpeas, garlic, lemon, parsley."),
        _context(platform_text="Add 2 cups pasta, then simmer until tender."),
    ],
    ids=["title-only", "promotional-caption", "ingredient-names", "platform-text"],
)
def test_unsupported_sparse_text_is_rejected(context: AcquiredVideoContext) -> None:
    with pytest.raises(InsufficientTextEvidence):
        require_recipe_evidence(context)


@pytest.mark.parametrize(
    "context",
    [
        _context(
            transcript="Add 2 cans chickpeas and simmer for ten minutes."
        ),
        _context(transcript="1 slice bread. Toast the bread."),
        _context(
            linked_document=(
                "Ingredients: 500 g potatoes. Method: chop the potatoes and "
                "roast until crisp."
            )
        ),
    ],
    ids=["transcript", "counted-ingredient", "creator-page"],
)
def test_recipe_bearing_text_is_accepted(context: AcquiredVideoContext) -> None:
    require_recipe_evidence(context)


def test_recipe_dense_caption_with_method_is_accepted() -> None:
    require_recipe_evidence(
        _context(
            description=(
                "Ingredients: 2 cups pasta, 1 tbsp butter, and 3 cloves garlic. "
                "Method: boil the pasta, then mix it with the butter and garlic."
            )
        )
    )


def test_recipe_dense_caption_can_supply_amounts_for_spoken_method() -> None:
    require_recipe_evidence(
        _context(
            description="2 cups pasta, 1 tbsp butter, and 3 cloves garlic.",
            transcript=(
                "Boil the pasta. Fry the garlic in butter, then mix everything."
            ),
        )
    )


def test_quantity_noun_alone_is_not_mistaken_for_a_cooking_action() -> None:
    with pytest.raises(InsufficientTextEvidence):
        require_recipe_evidence(_context(transcript="1 slice bread."))


def test_insufficient_evidence_has_a_typed_client_failure() -> None:
    assert (
        ImportFailure.INSUFFICIENT_TEXT_EVIDENCE.value
        == "insufficientTextEvidence"
    )
