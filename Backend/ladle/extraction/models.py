from decimal import Decimal

from pydantic import Field

from ladle.contracts.common import WireModel
from ladle.contracts.recipes import FieldUncertaintyDTO


class ExtractedIngredient(WireModel):
    name: str = Field(min_length=1)
    quantity_text: str | None = None
    normalized_quantity: Decimal | None = Field(default=None, ge=0)
    unit: str | None = None
    preparation: str | None = None
    confidence: float = Field(ge=0, le=1)
    uncertainty_reason: str | None = None


class ExtractedTimer(WireModel):
    label: str = Field(min_length=1)
    duration_seconds: int = Field(gt=0)


class ExtractedStep(WireModel):
    instruction: str = Field(min_length=1)
    ingredient_indices: list[int] = Field(default_factory=list)
    timers: list[ExtractedTimer] = Field(default_factory=list)
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


class RecipeExtraction(WireModel):
    title: str = Field(min_length=1)
    description: str
    creator_name: str | None = None
    servings: Decimal | None = Field(default=None, gt=0)
    preparation_minutes: int | None = Field(default=None, ge=0)
    cooking_minutes: int | None = Field(default=None, ge=0)
    total_minutes: int | None = Field(default=None, ge=0)
    ingredients: list[ExtractedIngredient] = Field(min_length=1)
    steps: list[ExtractedStep] = Field(min_length=1)
    nutrition: ExtractedNutrition | None = None
    uncertainties: list[FieldUncertaintyDTO] = Field(default_factory=list)
