"""Reject imports that lack enough textual evidence for a faithful recipe."""

from ladle.acquisition.coverage import (
    has_instructions,
    has_quantities,
    quantity_mention_count,
)
from ladle.acquisition.models import AcquiredVideoContext


class InsufficientTextEvidence(Exception):
    """No transcript, creator page, or dense caption supports the recipe."""


_MINIMUM_CAPTION_QUANTITIES = 3


def require_recipe_evidence(context: AcquiredVideoContext) -> None:
    """Require recipe-bearing text, excluding titles and sparse promotion."""

    recipe_text = " ".join(
        [
            *(segment.text for segment in context.transcript),
            *(document.text for document in context.linked_documents),
        ]
    )
    trusted_recipe = has_quantities(recipe_text) and has_instructions(recipe_text)
    caption_recipe = (
        quantity_mention_count(context.description) >= _MINIMUM_CAPTION_QUANTITIES
        and has_instructions(f"{context.description} {recipe_text}")
    )
    if not trusted_recipe and not caption_recipe:
        raise InsufficientTextEvidence(
            "text evidence lacks a quantified cooking method"
        )
