from enum import StrEnum

from pydantic import AnyHttpUrl, Field, model_validator

from ladle.contracts.common import (
    WireDateTime,
    WireDecimal,
    WireModel,
    WireUUID,
)


class RecipeSource(StrEnum):
    TIKTOK = "tiktok"
    INSTAGRAM = "instagram"
    YOUTUBE = "youtube"
    OTHER = "other"


class RecipeReviewStatus(StrEnum):
    READY = "ready"
    NEEDS_REVIEW = "needsReview"


class FieldUncertaintyDTO(WireModel):
    field: str = Field(min_length=1)
    reason: str = Field(min_length=1)
    confidence: float | None = Field(default=None, ge=0, le=1)


class RecipeImageDTO(WireModel):
    id: WireUUID
    remote_url: AnyHttpUrl


class IngredientDTO(WireModel):
    id: WireUUID
    quantity_text: str | None = None
    normalized_quantity: WireDecimal | None = None
    unit: str | None = None
    name: str = Field(min_length=1)
    preparation: str | None = None
    order_index: int = Field(ge=0)
    uncertainty: FieldUncertaintyDTO | None = None


class DetectedTimerDTO(WireModel):
    id: WireUUID
    label: str = Field(min_length=1)
    duration_seconds: int = Field(gt=0)


class RecipeStepDTO(WireModel):
    id: WireUUID
    order_index: int = Field(ge=0)
    instruction: str = Field(min_length=1)
    ingredient_ids: list[WireUUID] = Field(default_factory=list)
    source_start_seconds: float | None = Field(default=None, ge=0)
    source_end_seconds: float | None = Field(default=None, ge=0)
    timers: list[DetectedTimerDTO] = Field(default_factory=list)
    uncertainty: FieldUncertaintyDTO | None = None


class NutrientDTO(WireModel):
    id: WireUUID
    name: str = Field(min_length=1)
    amount: WireDecimal
    unit: str = Field(min_length=1)


class NutritionDTO(WireModel):
    calories: WireDecimal | None = None
    protein_grams: WireDecimal | None = None
    carbohydrate_grams: WireDecimal | None = None
    fat_grams: WireDecimal | None = None
    saturated_fat_grams: WireDecimal | None = None
    fiber_grams: WireDecimal | None = None
    sugar_grams: WireDecimal | None = None
    sodium_milligrams: WireDecimal | None = None
    other_nutrients: list[NutrientDTO] = Field(default_factory=list)
    serving_basis: WireDecimal
    is_estimated: bool


class RecipeDTO(WireModel):
    id: WireUUID
    title: str = Field(min_length=1)
    description: str
    creator_name: str | None = None
    source: RecipeSource
    original_url: AnyHttpUrl
    images: list[RecipeImageDTO] = Field(default_factory=list)
    preparation_minutes: int | None = Field(default=None, ge=0)
    cooking_minutes: int | None = Field(default=None, ge=0)
    total_minutes: int | None = Field(default=None, ge=0)
    servings: WireDecimal
    ingredients: list[IngredientDTO] = Field(default_factory=list)
    steps: list[RecipeStepDTO] = Field(default_factory=list)
    nutrition: NutritionDTO | None = None
    notes: list[str] = Field(default_factory=list)
    is_favorite: bool
    review_status: RecipeReviewStatus
    uncertainties: list[FieldUncertaintyDTO] = Field(default_factory=list)
    revision: int = Field(ge=1)
    created_at: WireDateTime
    updated_at: WireDateTime


class SyncChangeKind(StrEnum):
    UPSERT = "upsert"
    DELETE = "delete"


class RecipeChangeDTO(WireModel):
    sequence: int = Field(gt=0)
    recipe_id: WireUUID
    kind: SyncChangeKind
    recipe_revision: int = Field(gt=0)
    changed_at: WireDateTime
    recipe: RecipeDTO | None = None

    @model_validator(mode="after")
    def validate_payload_for_kind(self) -> "RecipeChangeDTO":
        if self.kind == SyncChangeKind.UPSERT and self.recipe is None:
            raise ValueError("upserts require a recipe payload")
        if self.kind == SyncChangeKind.DELETE and self.recipe is not None:
            raise ValueError("deletes cannot include a recipe payload")
        if self.recipe is not None:
            if self.recipe.id != self.recipe_id:
                raise ValueError("change and recipe IDs must match")
            if self.recipe.revision != self.recipe_revision:
                raise ValueError("change and recipe revisions must match")
        return self


class SyncPageDTO(WireModel):
    changes: list[RecipeChangeDTO]
    next_cursor: int = Field(ge=0)
    has_more: bool

    @model_validator(mode="after")
    def validate_cursor(self) -> "SyncPageDTO":
        if self.changes and self.next_cursor != self.changes[-1].sequence:
            raise ValueError("next cursor must equal the last returned sequence")
        return self
