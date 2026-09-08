from typing import Annotated, Literal

from pydantic import BeforeValidator, Field

from ladle.contracts.common import WireModel
from ladle.contracts.quantities import RecipeDecimal
from ladle.contracts.recipes import FieldUncertaintyDTO
from ladle.contracts.tags import CuisineTag, DietTag, coerce_tags

#: Diets and cuisines as the model wrote them, folded onto the closed lists.
#: A bare `list[DietTag]` would reject the payload over one invented tag, and
#: an entire recipe is not worth a stray "keto" — the same trade
#: `contracts.quantities` makes for fraction notation.
ExtractedDiets = Annotated[
    list[DietTag],
    BeforeValidator(lambda value: coerce_tags(DietTag, value)),
]
ExtractedCuisines = Annotated[
    list[CuisineTag],
    BeforeValidator(lambda value: coerce_tags(CuisineTag, value)),
]


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
    # What the dish is, for the cook who is filtering rather than searching.
    # Both are closed lists rendered into the prompt; anything else the model
    # offers is dropped on the way in.
    diets: ExtractedDiets = Field(default_factory=list)
    cuisines: ExtractedCuisines = Field(default_factory=list)
    # Free text on purpose. The prompt asks for the curated terms and permits
    # a new one where none fits; splitting the answer into the canonical set
    # and the proposals is the server's job, in `review.build_reviewed_
    # template`, because a model asked to classify its own tags moves terms
    # back and forth between the two on identical input.
    keywords: list[str] = Field(default_factory=list, max_length=40)
    # Creator caveats, substitutions, storage, and "full recipe at my link"
    # pointers — context that belongs beside the recipe, not inside its
    # ingredient or step lists.
    notes: list[str] = Field(default_factory=list)
    uncertainties: list[FieldUncertaintyDTO] = Field(default_factory=list)
