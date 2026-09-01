"""Reject imports that lack enough textual evidence for a faithful recipe."""

from ladle.acquisition.coverage import has_instructions
from ladle.acquisition.models import AcquiredVideoContext


class InsufficientTextEvidence(Exception):
    """No transcript, creator page, or caption describes a cooking method."""


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
    if not has_instructions(evidence):
        raise InsufficientTextEvidence("text evidence describes no cooking method")
