"""The three tag families a recipe carries, and how loose text becomes one.

One module because there is one vocabulary: the extraction prompt is rendered
from these enums, the DTO is typed by them, the Discover filter validates its
query parameters against them, and the client shares them through the contract.
A list that lived in two places would drift, and a drifted vocabulary is a
filter that quietly returns nothing.

Diet and cuisine are closed. Keywords are open at the edge: the prompt prefers
the curated list below, and anything else the model offers is kept as a
*proposal* — recorded, shown, never filterable — until somebody promotes it by
adding it to `RecipeKeyword` here and re-running the tag backfill.

Changing any of the three lists changes the extraction prompt, and the
extraction cache is keyed on `PROMPT_VERSION`: bump it in
`ladle/extraction/prompt.py` in the same change, or already-cached templates
will never be asked the new question.
"""

import re
from enum import StrEnum

#: Proposals a single recipe may carry. Generous enough that a model with an
#: unusual dish is not truncated, small enough that a prompt-injected list
#: cannot become a table.
MAX_KEYWORD_PROPOSALS = 10
MAX_KEYWORD_PROPOSAL_LENGTH = 40


class DietTag(StrEnum):
    """Dietary restrictions decidable from the ingredient list alone.

    That test is why the list is short. Halal, kosher and low-FODMAP turn on
    sourcing, certification or quantity rather than on what is in the bowl, so
    a model reading a caption would be guessing, and a cook who filtered on a
    guess would be misled about something that matters to them.
    """

    VEGETARIAN = "vegetarian"
    VEGAN = "vegan"
    PESCATARIAN = "pescatarian"
    GLUTEN_FREE = "glutenFree"
    DAIRY_FREE = "dairyFree"


class CuisineTag(StrEnum):
    """One tag per dish, chosen to cover a social-video corpus.

    Deliberately coarse. Thai and Vietnamese sit under `southeastAsian` and
    Greek under `mediterranean` because a filter with fifty near-empty
    buckets is worse than one with fifteen that each hold something — and
    because a model asked to choose between neighbours picks inconsistently.
    """

    AMERICAN = "american"
    BRITISH = "british"
    CARIBBEAN = "caribbean"
    CHINESE = "chinese"
    FRENCH = "french"
    INDIAN = "indian"
    ITALIAN = "italian"
    JAPANESE = "japanese"
    KOREAN = "korean"
    LATIN_AMERICAN = "latinAmerican"
    MEDITERRANEAN = "mediterranean"
    MEXICAN = "mexican"
    MIDDLE_EASTERN = "middleEastern"
    SOUTHEAST_ASIAN = "southeastAsian"
    WEST_AFRICAN = "westAfrican"


class RecipeKeyword(StrEnum):
    """How a dish is cooked, when it is eaten, and what it is.

    These are the terms Discover shelves will be built from, so each one has
    to be worth a shelf: something a cook would plausibly browse by, and
    something a model can decide from a caption and a method. Times are
    absent on purpose — Discover already filters on `maxTotalMinutes`, and a
    `under30Minutes` keyword would be a second, disagreeing answer.
    """

    ONE_POT = "onePot"
    WEEKNIGHT = "weeknight"
    MEAL_PREP = "mealPrep"
    HIGH_PROTEIN = "highProtein"
    BUDGET = "budget"
    COMFORT_FOOD = "comfortFood"
    AIR_FRYER = "airFryer"
    SLOW_COOKER = "slowCooker"
    PRESSURE_COOKER = "pressureCooker"
    SHEET_PAN = "sheetPan"
    NO_COOK = "noCook"
    BAKING = "baking"
    GRILLING = "grilling"
    FREEZER_FRIENDLY = "freezerFriendly"
    KID_FRIENDLY = "kidFriendly"
    PARTY_FOOD = "partyFood"
    BREAKFAST = "breakfast"
    BRUNCH = "brunch"
    LUNCHBOX = "lunchbox"
    DESSERT = "dessert"
    SNACK = "snack"
    SIDE_DISH = "sideDish"
    SOUP = "soup"
    SALAD = "salad"
    PASTA = "pasta"

    @property
    def shelf_title(self) -> str:
        """What a cook reads when this keyword is the heading of a shelf.

        Not `title`: `StrEnum` is a `str`, and a property by that name would
        quietly shadow `str.title()` for every caller of every tag.
        """

        return KEYWORD_TITLES[self]


#: The words for each keyword, beside the vocabulary that names them.
#:
#: Discover's keyword shelves are titled by the server, so the client draws
#: the heading it was handed rather than keeping a parallel list that would
#: drift the first time a keyword is promoted. The spellings are the ones the
#: app's filter menu already uses: tapping "See all" on a shelf turns it into
#: a filter pill, and a shelf and its pill must not name the same thing twice.
KEYWORD_TITLES: dict[RecipeKeyword, str] = {
    RecipeKeyword.ONE_POT: "One pot",
    RecipeKeyword.WEEKNIGHT: "Weeknight",
    RecipeKeyword.MEAL_PREP: "Meal prep",
    RecipeKeyword.HIGH_PROTEIN: "High protein",
    RecipeKeyword.BUDGET: "Budget",
    RecipeKeyword.COMFORT_FOOD: "Comfort food",
    RecipeKeyword.AIR_FRYER: "Air fryer",
    RecipeKeyword.SLOW_COOKER: "Slow cooker",
    RecipeKeyword.PRESSURE_COOKER: "Pressure cooker",
    RecipeKeyword.SHEET_PAN: "Sheet pan",
    RecipeKeyword.NO_COOK: "No cook",
    RecipeKeyword.BAKING: "Baking",
    RecipeKeyword.GRILLING: "Grilling",
    RecipeKeyword.FREEZER_FRIENDLY: "Freezer friendly",
    RecipeKeyword.KID_FRIENDLY: "Kid friendly",
    RecipeKeyword.PARTY_FOOD: "Party food",
    RecipeKeyword.BREAKFAST: "Breakfast",
    RecipeKeyword.BRUNCH: "Brunch",
    RecipeKeyword.LUNCHBOX: "Lunchbox",
    RecipeKeyword.DESSERT: "Dessert",
    RecipeKeyword.SNACK: "Snack",
    RecipeKeyword.SIDE_DISH: "Side dish",
    RecipeKeyword.SOUP: "Soup",
    RecipeKeyword.SALAD: "Salad",
    RecipeKeyword.PASTA: "Pasta",
}


_NON_ALPHANUMERIC = re.compile(r"[^a-z0-9]+")


def _slug(value: str) -> str:
    """Fold a written tag onto its identity: "Gluten-Free" and "glutenFree"."""

    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", value)
    return _NON_ALPHANUMERIC.sub("", spaced.casefold())


def _index[TagT: StrEnum](vocabulary: type[TagT]) -> dict[str, TagT]:
    return {_slug(member.value): member for member in vocabulary}


def coerce_tags[TagT: StrEnum](
    vocabulary: type[TagT],
    values: object,
) -> list[TagT]:
    """The members of `vocabulary` named in `values`, in vocabulary order.

    Anything off the list is dropped rather than raised. A closed enum on the
    extraction model would fail the whole payload over one invented cuisine,
    and losing an entire recipe's ingredients and method to a stray tag is
    never the right trade — the same reasoning that made fractions parse
    rather than reject in `extraction/models.py`.
    """

    if not isinstance(values, list):
        return []
    index = _index(vocabulary)
    found = {
        index[key]
        for value in values
        if isinstance(value, str) and (key := _slug(value)) in index
    }
    return [member for member in vocabulary if member in found]


def normalize_proposal(value: str) -> str | None:
    """A proposed keyword in the shape a canonical one would take, or None.

    Hyphenated lower case rather than the camel case of the enum, so that a
    proposal reads as the unreviewed thing it is everywhere it is displayed.
    """

    spaced = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", " ", value)
    parts = _NON_ALPHANUMERIC.sub(" ", spaced.casefold()).split()
    if not parts:
        return None
    return "-".join(parts)[:MAX_KEYWORD_PROPOSAL_LENGTH].strip("-") or None


def split_keywords(values: object) -> tuple[list[RecipeKeyword], list[str]]:
    """Separate what the curated list already covers from what it does not.

    The model is asked for one list and never for this split: asked to
    self-classify it puts canonical terms in the proposals and back again,
    and the two stores exist precisely so that judgement is not the model's.
    """

    canonical = coerce_tags(RecipeKeyword, values)
    if not isinstance(values, list):
        return canonical, []
    known = _index(RecipeKeyword)
    proposals: list[str] = []
    for value in values:
        if not isinstance(value, str) or _slug(value) in known:
            continue
        proposal = normalize_proposal(value)
        if proposal is not None and proposal not in proposals:
            proposals.append(proposal)
    return canonical, proposals[:MAX_KEYWORD_PROPOSALS]
