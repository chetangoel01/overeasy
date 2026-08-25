import re
from dataclasses import dataclass

from ladle.acquisition.models import AcquiredVideoContext

_QUANTITY = re.compile(
    r"\b(?:\d+(?:[./]\d+)?|one|two|three|four|five|six|half|quarter)"
    r"\s*(?:cups?|tbsp|tablespoons?|tsp|teaspoons?|grams?|g|kg|ml|"
    r"liters?|litres?|ounces?|oz|pounds?|lb|cloves?|cans?|pinch(?:es)?|"
    r"slices?|pieces?|packages?|packets?|bunches?|sprigs?|stalks?|heads?|"
    r"jars?|bottles?|boxes?|bags?|sticks?)\b",
    re.IGNORECASE,
)
_INSTRUCTION = re.compile(
    r"\b(?:add|bake|blend|boil|chill|chop|combine|cook|drain|fold|fry|grate|"
    r"heat|knead|marinate|mix|peel|pour|preheat|refrigerate|rinse|roast|"
    r"saute|season|serve|simmer|slice|stir|toast|transfer|whisk)\b",
    re.IGNORECASE,
)


def has_quantities(text: str) -> bool:
    return _QUANTITY.search(text) is not None


def quantity_mention_count(text: str) -> int:
    return len(_QUANTITY.findall(text))


def has_instructions(text: str) -> bool:
    # A count such as "1 slice bread" names an ingredient amount; `slice`
    # must not double as the action that makes the same line recipe-bearing.
    return _INSTRUCTION.search(_QUANTITY.sub("", text)) is not None


@dataclass(frozen=True)
class CoverageReport:
    has_quantities: bool
    has_instructions: bool
    sufficient_for_extraction: bool
    requires_review: bool
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
    recipe_text = " ".join(
        [
            *(segment.text for segment in context.transcript),
            *(document.text for document in context.linked_documents),
        ]
    )
    spoken = " ".join(
        [context.title or "", context.description, recipe_text]
    )
    platform_text = " ".join(
        value.text for value in context.visual_observations
    )
    spoken_has_quantities = has_quantities(spoken)
    platform_has_quantities = has_quantities(platform_text)
    quantities = spoken_has_quantities or platform_has_quantities
    instructions = has_instructions(f"{spoken} {platform_text}")
    sufficient = quantities and instructions
    recipe_evidence = has_quantities(recipe_text) and has_instructions(recipe_text)
    return CoverageReport(
        has_quantities=quantities,
        has_instructions=instructions,
        sufficient_for_extraction=sufficient,
        requires_review=not sufficient,
        has_recipe_evidence=recipe_evidence,
    )
