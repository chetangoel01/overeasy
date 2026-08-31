from collections.abc import Mapping
from decimal import Decimal
from enum import StrEnum
from typing import Annotated

from pydantic import AnyHttpUrl, Field, model_validator

from ladle.contracts.common import (
    WireDateTime,
    WireDecimal,
    WireModel,
    WireUUID,
)

MAX_RECIPE_DECODE_DEPTH = 8
MAX_RECIPE_DECODE_NODES = 10_000
MAX_RECIPE_COLLECTION_ENTRIES = 5_000
MAX_RECIPE_DECIMAL = Decimal("1000000")
MAX_RECIPE_MINUTES = 43_200
MAX_RECIPE_TIMER_SECONDS = 2_592_000
MAX_RECIPE_SOURCE_SECONDS = 86_400
MAX_RECIPE_NOTES = 100
MAX_RECIPE_NOTE_LENGTH = 2_000

NonnegativeRecipeDecimal = Annotated[
    WireDecimal,
    Field(
        ge=Decimal(0),
        le=MAX_RECIPE_DECIMAL,
        max_digits=13,
        decimal_places=6,
        allow_inf_nan=False,
    ),
]
PositiveRecipeDecimal = Annotated[
    WireDecimal,
    Field(
        gt=Decimal(0),
        le=MAX_RECIPE_DECIMAL,
        max_digits=13,
        decimal_places=6,
        allow_inf_nan=False,
    ),
]
ServingDecimal = Annotated[
    WireDecimal,
    Field(
        gt=Decimal(0),
        le=Decimal("10000"),
        max_digits=11,
        decimal_places=6,
        allow_inf_nan=False,
    ),
]
RecipeNote = Annotated[
    str,
    Field(min_length=1, max_length=MAX_RECIPE_NOTE_LENGTH),
]


class RecipeSource(StrEnum):
    TIKTOK = "tiktok"
    INSTAGRAM = "instagram"
    YOUTUBE = "youtube"
    OTHER = "other"


class RecipeReviewStatus(StrEnum):
    READY = "ready"
    NEEDS_REVIEW = "needsReview"


class FieldUncertaintyDTO(WireModel):
    field: str = Field(min_length=1, max_length=255)
    reason: str = Field(min_length=1, max_length=1_000)
    confidence: float | None = Field(
        default=None,
        ge=0,
        le=1,
        allow_inf_nan=False,
    )


class RecipeImageDTO(WireModel):
    id: WireUUID
    remote_url: AnyHttpUrl = Field(max_length=2_048)


class IngredientDTO(WireModel):
    id: WireUUID
    quantity_text: str | None = Field(default=None, max_length=100)
    normalized_quantity: NonnegativeRecipeDecimal | None = None
    unit: str | None = Field(default=None, max_length=50)
    name: str = Field(min_length=1, max_length=300)
    preparation: str | None = Field(default=None, max_length=500)
    order_index: int = Field(ge=0, le=10_000)
    uncertainty: FieldUncertaintyDTO | None = None


class DetectedTimerDTO(WireModel):
    id: WireUUID
    label: str = Field(min_length=1, max_length=200)
    duration_seconds: int = Field(gt=0, le=MAX_RECIPE_TIMER_SECONDS)


class RecipeStepDTO(WireModel):
    id: WireUUID
    order_index: int = Field(ge=0, le=10_000)
    instruction: str = Field(min_length=1, max_length=5_000)
    ingredient_ids: list[WireUUID] = Field(default_factory=list, max_length=200)
    source_start_seconds: float | None = Field(
        default=None,
        ge=0,
        le=MAX_RECIPE_SOURCE_SECONDS,
        allow_inf_nan=False,
    )
    source_end_seconds: float | None = Field(
        default=None,
        ge=0,
        le=MAX_RECIPE_SOURCE_SECONDS,
        allow_inf_nan=False,
    )
    timers: list[DetectedTimerDTO] = Field(default_factory=list, max_length=20)
    uncertainty: FieldUncertaintyDTO | None = None

    @model_validator(mode="after")
    def validate_source_window(self) -> "RecipeStepDTO":
        if (
            self.source_start_seconds is not None
            and self.source_end_seconds is not None
            and self.source_end_seconds < self.source_start_seconds
        ):
            raise ValueError("source end must not precede source start")
        return self


class NutrientDTO(WireModel):
    id: WireUUID
    name: str = Field(min_length=1, max_length=200)
    amount: NonnegativeRecipeDecimal
    unit: str = Field(min_length=1, max_length=50)


class NutritionDTO(WireModel):
    calories: NonnegativeRecipeDecimal | None = None
    protein_grams: NonnegativeRecipeDecimal | None = None
    carbohydrate_grams: NonnegativeRecipeDecimal | None = None
    fat_grams: NonnegativeRecipeDecimal | None = None
    saturated_fat_grams: NonnegativeRecipeDecimal | None = None
    fiber_grams: NonnegativeRecipeDecimal | None = None
    sugar_grams: NonnegativeRecipeDecimal | None = None
    sodium_milligrams: NonnegativeRecipeDecimal | None = None
    other_nutrients: list[NutrientDTO] = Field(
        default_factory=list,
        max_length=100,
    )
    serving_basis: PositiveRecipeDecimal
    is_estimated: bool


class RecipeDTO(WireModel):
    id: WireUUID
    title: str = Field(min_length=1, max_length=300)
    description: str = Field(max_length=10_000)
    creator_name: str | None = Field(default=None, max_length=200)
    source: RecipeSource
    original_url: AnyHttpUrl = Field(max_length=2_048)
    images: list[RecipeImageDTO] = Field(default_factory=list, max_length=20)
    preparation_minutes: int | None = Field(
        default=None,
        ge=0,
        le=MAX_RECIPE_MINUTES,
    )
    cooking_minutes: int | None = Field(
        default=None,
        ge=0,
        le=MAX_RECIPE_MINUTES,
    )
    total_minutes: int | None = Field(
        default=None,
        ge=0,
        le=MAX_RECIPE_MINUTES,
    )
    servings: ServingDecimal
    ingredients: list[IngredientDTO] = Field(default_factory=list, max_length=200)
    steps: list[RecipeStepDTO] = Field(default_factory=list, max_length=200)
    nutrition: NutritionDTO | None = None
    notes: list[RecipeNote] = Field(
        default_factory=list,
        max_length=MAX_RECIPE_NOTES,
    )
    is_favorite: bool
    review_status: RecipeReviewStatus
    uncertainties: list[FieldUncertaintyDTO] = Field(
        default_factory=list,
        max_length=200,
    )
    revision: int = Field(ge=1, le=2_147_483_647)
    created_at: WireDateTime
    updated_at: WireDateTime

    @model_validator(mode="before")
    @classmethod
    def validate_decoded_complexity(cls, value: object) -> object:
        if not isinstance(value, (Mapping, list, tuple)):
            return value
        nodes = 0
        stack: list[tuple[object, int]] = [(value, 1)]
        while stack:
            current, depth = stack.pop()
            if depth > MAX_RECIPE_DECODE_DEPTH:
                raise ValueError("recipe nesting is too deep")
            nodes += 1
            if nodes > MAX_RECIPE_DECODE_NODES:
                raise ValueError("recipe decoded object complexity is too high")
            if isinstance(current, Mapping):
                stack.extend((child, depth + 1) for child in current.values())
            elif isinstance(current, (list, tuple)):
                stack.extend((child, depth + 1) for child in current)
        return value

    @model_validator(mode="after")
    def validate_graph(self) -> "RecipeDTO":
        ingredient_ids = {ingredient.id for ingredient in self.ingredients}
        collection_entries = (
            len(self.images)
            + len(self.ingredients)
            + len(self.steps)
            + len(self.notes)
            + len(self.uncertainties)
            + (len(self.nutrition.other_nutrients) if self.nutrition is not None else 0)
        )
        for step in self.steps:
            if len(set(step.ingredient_ids)) != len(step.ingredient_ids):
                raise ValueError("step ingredient references must be unique")
            if any(value not in ingredient_ids for value in step.ingredient_ids):
                raise ValueError("step references an unknown ingredient")
            collection_entries += len(step.ingredient_ids) + len(step.timers)
            if step.uncertainty is not None:
                collection_entries += 1
        collection_entries += sum(
            ingredient.uncertainty is not None for ingredient in self.ingredients
        )
        if collection_entries > MAX_RECIPE_COLLECTION_ENTRIES:
            raise ValueError("recipe collection complexity is too high")
        return self


class DiscoverRecipeDTO(WireModel):
    source_id: WireUUID
    title: str = Field(min_length=1, max_length=300)
    description: str = Field(max_length=10_000)
    creator_name: str | None = Field(default=None, max_length=200)
    source: RecipeSource
    original_url: AnyHttpUrl = Field(max_length=2_048)
    image_url: AnyHttpUrl | None = Field(default=None, max_length=2_048)
    saved_count: int = Field(gt=0)
    saved_recipe_id: WireUUID | None = None


class DiscoverSort(StrEnum):
    """How the Discover feed is ordered.

    Ordering is the server's job now that the feed is paged: sorting one page
    on the client would only sort that page, which is worse than not sorting.
    """

    POPULAR = "popular"
    ALPHABETICAL = "alphabetical"


class DiscoverPageDTO(WireModel):
    items: list[DiscoverRecipeDTO] = Field(max_length=100)
    next_cursor: int = Field(ge=0)
    has_more: bool


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
