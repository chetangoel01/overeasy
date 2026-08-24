"""Reject imports that lack enough textual evidence for a faithful recipe."""

from ladle.acquisition.coverage import has_instructions, has_quantities
from ladle.acquisition.models import AcquiredVideoContext


class InsufficientTextEvidence(Exception):
    """No transcript or creator page supports a quantified cooking method."""


def require_recipe_evidence(context: AcquiredVideoContext) -> None:
    """Require recipe-bearing evidence, excluding titles and promotional copy."""

    recipe_text = " ".join(
        [
            *(segment.text for segment in context.transcript),
            *(document.text for document in context.linked_documents),
        ]
    )
    if not has_quantities(recipe_text) or not has_instructions(recipe_text):
        raise InsufficientTextEvidence(
            "transcript or creator page lacks a quantified cooking method"
        )
