"""Reject imports that lack enough textual evidence for a faithful recipe."""

from ladle.acquisition.coverage import has_instructions
from ladle.acquisition.models import AcquiredVideoContext, MediaKind


class InsufficientTextEvidence(Exception):
    """No transcript, creator page, or caption describes a cooking method."""


class PhotoPostNeedsManualEntry(InsufficientTextEvidence):
    """A photo post whose recipe is in the pictures rather than the caption.

    A subclass, not a sibling, because everything that already handles the
    general case is still right: nothing was extracted and nothing was
    persisted. What differs is only what the cook should be told. "We couldn't
    read the recipe" reads as a verdict on their post, when the post is fine
    and the limit is ours — this pipeline reads captions, not pictures. The
    honest answer names that and offers somewhere to type the recipe in.
    """


def require_recipe_evidence(context: AcquiredVideoContext) -> None:
    """Require text that describes cooking, from any source.

    This used to also demand at least three quantity mentions in a caption.
    That rejected a great many real recipes: creators routinely list
    ingredients with no amounts at all — "chicken breast, olive oil, lemon
    juice" — and then give a perfectly clear method. Counting quantities was
    standing in for "is this a recipe", and the two come apart exactly there.

    What is left is the honest question: does anything here describe cooking?
    A promotional caption that never says how to make the dish still fails.
    Deciding what to do about missing amounts is the extractor's job, not
    this gate's — the prompt tells it to assemble what it can and mark what
    it could not.
    """
    evidence = " ".join(
        [
            context.description,
            *(segment.text for segment in context.transcript),
            *(document.text for document in context.linked_documents),
        ]
    )
    if has_instructions(evidence):
        return
    if context.media_kind is MediaKind.PHOTO:
        raise PhotoPostNeedsManualEntry("photo post caption carries no recipe")
    raise InsufficientTextEvidence("text evidence describes no cooking method")
