import re
from dataclasses import dataclass

from ladle.acquisition.models import AcquiredVideoContext

_QUANTITY = re.compile(
    r"\b(?:\d+(?:[./]\d+)?|one|two|three|four|five|six|half|quarter)"
    r"\s*(?:cups?|tbsp|tablespoons?|tsp|teaspoons?|grams?|g|kg|ml|"
    r"liters?|litres?|ounces?|oz|pounds?|lb|cloves?|cans?|pinch(?:es)?)\b",
    re.IGNORECASE,
)
_INSTRUCTION = re.compile(
    r"\b(?:add|bake|blend|boil|chop|combine|cook|fold|fry|heat|mix|pour|"
    r"roast|season|simmer|slice|stir|whisk)\b",
    re.IGNORECASE,
)


def has_quantities(text: str) -> bool:
    return _QUANTITY.search(text) is not None


def has_instructions(text: str) -> bool:
    return _INSTRUCTION.search(text) is not None


@dataclass(frozen=True)
class CoverageReport:
    has_quantities: bool
    has_instructions: bool
    sufficient_for_extraction: bool
    requires_visual_fallback: bool
    requires_review: bool
    used_visual_evidence: bool
    #: Whether anything here reports what the recipe actually *is*, as opposed
    #: to what the post said about it. A transcript is the creator narrating
    #: the dish; a linked page is the creator's own written version. A caption
    #: is neither — it is a promo blurb that happens to contain numbers.
    has_recipe_evidence: bool

    @property
    def sufficient_without_transcription(self) -> bool:
        """Whether we can justify never listening to the video.

        Captions routinely name a quantity and a cooking verb while omitting
        the technique, timing and substitutions the creator says out loud. So
        matching keywords in a caption is not grounds for skipping the audio;
        only already holding real recipe evidence is.
        """

        return self.sufficient_for_extraction and self.has_recipe_evidence


def assess_coverage(context: AcquiredVideoContext) -> CoverageReport:
    spoken = " ".join(
        [
            context.title or "",
            context.description,
            *(segment.text for segment in context.transcript),
            *(document.text for document in context.linked_documents),
        ]
    )
    visual = " ".join(value.text for value in context.visual_observations)
    spoken_has_quantities = has_quantities(spoken)
    visual_has_quantities = has_quantities(visual)
    quantities = spoken_has_quantities or visual_has_quantities
    instructions = has_instructions(f"{spoken} {visual}")
    sufficient = quantities and instructions
    return CoverageReport(
        has_quantities=quantities,
        has_instructions=instructions,
        sufficient_for_extraction=sufficient,
        requires_visual_fallback=not sufficient and not visual_has_quantities,
        requires_review=not sufficient,
        used_visual_evidence=bool(context.visual_observations),
        has_recipe_evidence=bool(context.transcript or context.linked_documents),
    )
