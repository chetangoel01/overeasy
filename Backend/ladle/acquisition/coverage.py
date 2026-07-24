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


@dataclass(frozen=True)
class CoverageReport:
    has_quantities: bool
    has_instructions: bool
    sufficient_for_extraction: bool
    requires_visual_fallback: bool
    requires_review: bool
    used_visual_evidence: bool


def assess_coverage(context: AcquiredVideoContext) -> CoverageReport:
    spoken = " ".join(
        [
            context.title or "",
            context.description,
            *(segment.text for segment in context.transcript),
        ]
    )
    visual = " ".join(value.text for value in context.visual_observations)
    spoken_has_quantities = _QUANTITY.search(spoken) is not None
    visual_has_quantities = _QUANTITY.search(visual) is not None
    has_quantities = spoken_has_quantities or visual_has_quantities
    has_instructions = _INSTRUCTION.search(f"{spoken} {visual}") is not None
    sufficient = has_quantities and has_instructions
    return CoverageReport(
        has_quantities=has_quantities,
        has_instructions=has_instructions,
        sufficient_for_extraction=sufficient,
        requires_visual_fallback=not sufficient and not visual_has_quantities,
        requires_review=not sufficient,
        used_visual_evidence=bool(context.visual_observations),
    )
