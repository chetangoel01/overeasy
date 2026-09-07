from uuid import uuid4

import pytest

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    MediaKind,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)
from ladle.contracts.imports import ImportFailure
from ladle.extraction.evidence_gate import (
    InsufficientTextEvidence,
    PhotoPostNeedsManualEntry,
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
        _context(transcript="Chickpeas, garlic, lemon, parsley."),
        _context(platform_text="Add 2 cups pasta, then simmer until tender."),
    ],
    ids=["title-only", "ingredient-names", "platform-text"],
)
def test_text_without_a_cooking_method_is_rejected(
    context: AcquiredVideoContext,
) -> None:
    with pytest.raises(InsufficientTextEvidence):
        require_recipe_evidence(context)


def test_caption_without_amounts_is_accepted() -> None:
    """The case the old three-quantity threshold rejected.

    Every ingredient here is unquantified, which is how a great many TikTok
    creators write. The method is unmistakable, so the recipe survives to the
    extractor, which decides what to do about the missing amounts.
    """
    context = _context(
        description=(
            "lemon pepper chicken skewers. Ingredients: chicken breast, "
            "olive oil, lemon juice, minced garlic, onion powder, paprika. "
            "Air fry at 400F for 12 minutes, flip the chicken and air fry "
            "for another 10 minutes."
        )
    )

    require_recipe_evidence(context)


def test_a_thin_caption_now_reaches_the_extractor() -> None:
    """A deliberate consequence of dropping the quantity threshold.

    This caption barely describes cooking and used to be rejected outright.
    It now passes the gate, because the alternative was throwing away real
    recipes that simply never stated amounts. The extractor labels a method
    it had to reconstruct as inferred, and the server routes that to human
    review rather than presenting it as the creator's own.
    """
    context = _context(
        description=(
            "The coziest dinner! Add 2 cups pasta and simmer tonight. "
            "Full recipe in bio."
        )
    )

    require_recipe_evidence(context)


@pytest.mark.parametrize(
    "context",
    [
        _context(transcript="Add 2 cans chickpeas and simmer for ten minutes."),
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
    assert ImportFailure.INSUFFICIENT_TEXT_EVIDENCE.value == "insufficientTextEvidence"


def photo_context(description: str) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="7481234567890123456",
            canonical_url=("https://www.tiktok.com/@creator/photo/7481234567890123456"),
            source_revision="1",
        ),
        is_public=True,
        media_kind=MediaKind.PHOTO,
        description=description,
    )


def test_a_carousel_whose_caption_carries_the_recipe_passes_the_gate() -> None:
    require_recipe_evidence(
        photo_context(
            "Hot Honey Chicken Tacos\n2 chicken breasts, 1 cup hot honey.\n"
            "Sear the chicken, then simmer the sauce until it thickens."
        )
    )


def test_a_carousel_whose_recipe_is_only_in_the_pictures_asks_the_cook() -> None:
    """The recipe exists — we just cannot read it. That is not the same failure.

    A generic "couldn't read the recipe" tells the cook the post was no good.
    Here the post is fine and the limitation is ours, so the sheet has to say
    so and offer somewhere to type it.
    """

    with pytest.raises(PhotoPostNeedsManualEntry):
        require_recipe_evidence(photo_context("#food #recipe #80s #retro #candy"))


def test_an_empty_carousel_caption_asks_the_cook_too() -> None:
    with pytest.raises(PhotoPostNeedsManualEntry):
        require_recipe_evidence(photo_context(""))


def test_a_video_post_keeps_the_generic_failure() -> None:
    with pytest.raises(InsufficientTextEvidence) as raised:
        require_recipe_evidence(_context(description="You need this tonight."))

    assert not isinstance(raised.value, PhotoPostNeedsManualEntry)


def test_the_photo_failure_is_still_an_insufficient_evidence_failure() -> None:
    # Everything that already handles the general case — the orchestrator's
    # catch list, the retry rules — must keep working unchanged.
    assert issubclass(PhotoPostNeedsManualEntry, InsufficientTextEvidence)
    assert (
        ImportFailure.PHOTO_POST_NEEDS_MANUAL_ENTRY.value == "photoPostNeedsManualEntry"
    )
