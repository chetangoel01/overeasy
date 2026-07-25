from decimal import Decimal
from typing import Literal

from pydantic import Field

from ladle.contracts.common import WireModel
from ladle.contracts.recipes import FieldUncertaintyDTO


class ExtractedIngredient(WireModel):
    name: str = Field(min_length=1)
    quantity_text: str | None = None
    normalized_quantity: Decimal | None = Field(default=None, ge=0)
    unit: str | None = None
    preparation: str | None = None
    # Mass/volume for the whole ingredient, which is what makes yield math
    # and scaling possible; creators often write it already ("2 cans (450g)").
    metric_amount: Decimal | None = Field(default=None, ge=0)
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
    amount: Decimal = Field(ge=0)
    unit: str = Field(min_length=1)


class ExtractedNutrition(WireModel):
    calories: Decimal | None = Field(default=None, ge=0)
    protein_grams: Decimal | None = Field(default=None, ge=0)
    carbohydrate_grams: Decimal | None = Field(default=None, ge=0)
    fat_grams: Decimal | None = Field(default=None, ge=0)
    saturated_fat_grams: Decimal | None = Field(default=None, ge=0)
    fiber_grams: Decimal | None = Field(default=None, ge=0)
    sugar_grams: Decimal | None = Field(default=None, ge=0)
    sodium_milligrams: Decimal | None = Field(default=None, ge=0)
    other_nutrients: list[ExtractedNutrient] = Field(default_factory=list)
    serving_basis: Decimal | None = Field(default=None, gt=0)


MethodProvenance = Literal["explicit", "partial", "inferred"]
ServingsBasis = Literal["stated", "estimatedFromYield", "unknown"]


class RecipeExtraction(WireModel):
    title: str = Field(min_length=1)
    description: str
    creator_name: str | None = None
    servings: Decimal | None = Field(default=None, gt=0)
    # How servings was arrived at, so the server never presents a guess as
    # a stated fact.
    servings_basis: ServingsBasis = "unknown"
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
