import re
from decimal import Decimal, InvalidOperation
from fractions import Fraction
from typing import Annotated, Any, Literal

from pydantic import BeforeValidator, Field

from ladle.contracts.common import WireModel
from ladle.contracts.recipes import FieldUncertaintyDTO

# "1/2", "2/3", "1 1/2" — how recipes are actually written, and so how models
# write them back. Pydantic rejects them as decimals, and because a rejected
# field fails the whole payload, one "2/3 cup" used to discard an entire
# extraction: every ingredient, every step, over a notation choice.
_FRACTION = re.compile(r"^(?:(\d+)\s+)?(\d+)\s*/\s*(\d+)$")
_VULGAR = {
    "¼": Fraction(1, 4),
    "½": Fraction(1, 2),
    "¾": Fraction(3, 4),
    "⅐": Fraction(1, 7),
    "⅓": Fraction(1, 3),
    "⅔": Fraction(2, 3),
    "⅕": Fraction(1, 5),
    "⅖": Fraction(2, 5),
    "⅗": Fraction(3, 5),
    "⅘": Fraction(4, 5),
    "⅙": Fraction(1, 6),
    "⅚": Fraction(5, 6),
    "⅛": Fraction(1, 8),
    "⅜": Fraction(3, 8),
    "⅝": Fraction(5, 8),
    "⅞": Fraction(7, 8),
}


def _decimal_from_fraction(value: Any) -> Any:
    """Accept a fraction where a decimal is expected; pass anything else on.

    Left for pydantic to reject when it is neither, so genuinely bad input
    still fails rather than being coerced into a plausible number.
    """

    if not isinstance(value, str):
        return value
    text = value.strip()
    if not text:
        return value
    if text in _VULGAR:
        return _as_decimal(_VULGAR[text])
    # "1½"
    if len(text) > 1 and text[-1] in _VULGAR:
        whole = text[:-1].strip()
        if whole.isdigit():
            return _as_decimal(int(whole) + _VULGAR[text[-1]])
    match = _FRACTION.match(text)
    if match is None:
        return value
    whole_part, numerator, denominator = match.groups()
    if int(denominator) == 0:
        return value
    total = Fraction(int(numerator), int(denominator))
    if whole_part is not None:
        total += int(whole_part)
    return _as_decimal(total)


def _as_decimal(value: Fraction) -> Decimal:
    try:
        return round(Decimal(value.numerator) / Decimal(value.denominator), 6)
    except (InvalidOperation, ZeroDivisionError):  # pragma: no cover - guarded above
        return Decimal(0)


#: A decimal that also accepts the fractions recipes are written in.
RecipeDecimal = Annotated[Decimal, BeforeValidator(_decimal_from_fraction)]


class ExtractedIngredient(WireModel):
    name: str = Field(min_length=1)
    quantity_text: str | None = None
    normalized_quantity: RecipeDecimal | None = Field(default=None, ge=0)
    unit: str | None = None
    preparation: str | None = None
    # Mass/volume for the whole ingredient, which is what makes yield math
    # and scaling possible; creators often write it already ("2 cans (450g)").
    metric_amount: RecipeDecimal | None = Field(default=None, ge=0)
    metric_unit: Literal["g", "ml"] | None = None
    # "Salt to taste" is a real ingredient with no real quantity; flagging it
    # keeps it out of the missing-quantity ratio that drives review.
    is_to_taste: bool = False
    confidence: float = Field(ge=0, le=1)
    uncertainty_reason: str | None = None


class ExtractedTimer(WireModel):
    label: str = Field(min_length=1)
    duration_seconds: int = Field(gt=0)


class ExtractedStep(WireModel):
    instruction: str = Field(min_length=1)
    ingredient_indices: list[int] = Field(default_factory=list)
    timers: list[ExtractedTimer] = Field(default_factory=list)
    # Transcript window this step was drawn from. Grounds timing inference
    # and lets the client jump the embedded player to the right moment.
    source_start_seconds: float | None = Field(default=None, ge=0)
    source_end_seconds: float | None = Field(default=None, ge=0)
    confidence: float = Field(ge=0, le=1)
    uncertainty_reason: str | None = None


class ExtractedNutrient(WireModel):
    name: str = Field(min_length=1)
    amount: RecipeDecimal = Field(ge=0)
    unit: str = Field(min_length=1)


NutritionBasis = Literal["creatorStated", "usdaCalculated", "unknown"]


class ExtractedNutrition(WireModel):
    calories: RecipeDecimal | None = Field(default=None, ge=0)
    protein_grams: RecipeDecimal | None = Field(default=None, ge=0)
    carbohydrate_grams: RecipeDecimal | None = Field(default=None, ge=0)
    fat_grams: RecipeDecimal | None = Field(default=None, ge=0)
    saturated_fat_grams: RecipeDecimal | None = Field(default=None, ge=0)
    fiber_grams: RecipeDecimal | None = Field(default=None, ge=0)
    sugar_grams: RecipeDecimal | None = Field(default=None, ge=0)
    sodium_milligrams: RecipeDecimal | None = Field(default=None, ge=0)
    other_nutrients: list[ExtractedNutrient] = Field(default_factory=list)
    serving_basis: RecipeDecimal | None = Field(
        default=None,
        gt=0,
        description=(
            "Number of servings represented by every nutrition value; use 1 "
            "when the values are per serving"
        ),
    )
    basis: NutritionBasis
    evidence: str | None = Field(default=None, max_length=2_000)


MethodProvenance = Literal["explicit", "partial", "inferred"]
ServingsBasis = Literal["stated", "estimatedFromYield", "unknown"]
TimeBasis = Literal["stated", "estimated", "unknown"]


class RecipeExtraction(WireModel):
    title: str = Field(min_length=1)
    description: str
    creator_name: str | None = None
    servings: RecipeDecimal | None = Field(default=None, gt=0)
    # How servings was arrived at, so the server never presents a guess as
    # a stated fact.
    servings_basis: ServingsBasis = "unknown"
    # Whether the creator gave a time or the model worked one out from the
    # method, so the server can label the estimate instead of passing it
    # off as something they said.
    time_basis: TimeBasis = "unknown"
    preparation_minutes: int | None = Field(default=None, ge=0)
    cooking_minutes: int | None = Field(default=None, ge=0)
    total_minutes: int | None = Field(default=None, ge=0)
    ingredients: list[ExtractedIngredient] = Field(min_length=1)
    steps: list[ExtractedStep] = Field(min_length=1)
    # Whether the source actually described a method or the model had to
    # reconstruct one. "inferred" always forces human review.
    method_provenance: MethodProvenance = "explicit"
    nutrition: ExtractedNutrition | None = None
    # Creator caveats, substitutions, storage, and "full recipe at my link"
    # pointers — context that belongs beside the recipe, not inside its
    # ingredient or step lists.
    notes: list[str] = Field(default_factory=list)
    uncertainties: list[FieldUncertaintyDTO] = Field(default_factory=list)
