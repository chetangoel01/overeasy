from datetime import datetime
from typing import Literal
from uuid import UUID, uuid4

from pydantic import Field, model_validator
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.contracts.common import WireDecimal, WireModel
from ladle.contracts.recipes import (
    DetectedTimerDTO,
    FieldUncertaintyDTO,
    IngredientDTO,
    NutrientDTO,
    NutritionDTO,
    RecipeDTO,
    RecipeReviewStatus,
    RecipeSource,
    RecipeStepDTO,
)
from ladle.db.models import (
    ExtractionCache,
    ImportJob,
    RecipeChange,
    RecipeImage,
)
from ladle.imports.reservations import ReservationService
from ladle.recipes.repository import RecipeRepository
from ladle.sync.sequence import allocate_sequence


class TemplateIngredient(WireModel):
    quantity_text: str | None = None
    normalized_quantity: WireDecimal | None = None
    unit: str | None = None
    name: str = Field(min_length=1)
    preparation: str | None = None
    metric_amount: WireDecimal | None = None
    metric_unit: Literal["g", "ml"] | None = None
    usda_search_term: str | None = Field(default=None, min_length=1)
    is_to_taste: bool = False
    order_index: int = Field(ge=0)
    uncertainty: FieldUncertaintyDTO | None = None


class TemplateTimer(WireModel):
    label: str = Field(min_length=1)
    duration_seconds: int = Field(gt=0)


class TemplateStep(WireModel):
    order_index: int = Field(ge=0)
    instruction: str = Field(min_length=1)
    ingredient_indexes: list[int] = Field(default_factory=list)
    timers: list[TemplateTimer] = Field(default_factory=list)
    source_start_seconds: float | None = Field(default=None, ge=0)
    source_end_seconds: float | None = Field(default=None, ge=0)
    uncertainty: FieldUncertaintyDTO | None = None


class TemplateNutrient(WireModel):
    name: str = Field(min_length=1)
    amount: WireDecimal
    unit: str = Field(min_length=1)


class TemplateNutrition(WireModel):
    calories: WireDecimal | None = None
    protein_grams: WireDecimal | None = None
    carbohydrate_grams: WireDecimal | None = None
    fat_grams: WireDecimal | None = None
    saturated_fat_grams: WireDecimal | None = None
    fiber_grams: WireDecimal | None = None
    sugar_grams: WireDecimal | None = None
    sodium_milligrams: WireDecimal | None = None
    other_nutrients: list[TemplateNutrient] = Field(default_factory=list)
    serving_basis: WireDecimal
    is_estimated: bool
    basis: Literal["creatorStated", "usdaCalculated", "unknown"]
    evidence: str | None = None


class RecipeTemplate(WireModel):
    title: str = Field(min_length=1)
    description: str
    creator_name: str | None = None
    source: RecipeSource
    original_url: str = Field(pattern=r"^https://")
    preparation_minutes: int | None = Field(default=None, ge=0)
    cooking_minutes: int | None = Field(default=None, ge=0)
    total_minutes: int | None = Field(default=None, ge=0)
    servings: WireDecimal
    servings_basis: Literal["stated", "estimatedFromYield", "unknown"] = "unknown"
    ingredients: list[TemplateIngredient] = Field(default_factory=list)
    steps: list[TemplateStep] = Field(default_factory=list)
    nutrition: TemplateNutrition | None = None
    notes: list[str] = Field(default_factory=list)
    review_status: RecipeReviewStatus
    uncertainties: list[FieldUncertaintyDTO] = Field(default_factory=list)

    @model_validator(mode="after")
    def validate_ingredient_references(self) -> "RecipeTemplate":
        ingredient_count = len(self.ingredients)
        for step in self.steps:
            if any(
                index < 0 or index >= ingredient_count
                for index in step.ingredient_indexes
            ):
                raise ValueError("step references an unknown template ingredient")
            if len(set(step.ingredient_indexes)) != len(step.ingredient_indexes):
                raise ValueError("step ingredient references must be unique")
        return self

    @classmethod
    def from_recipe(cls, recipe: RecipeDTO) -> "RecipeTemplate":
        ingredient_indexes = {
            ingredient.id: index for index, ingredient in enumerate(recipe.ingredients)
        }
        nutrition = recipe.nutrition
        return cls(
            title=recipe.title,
            description=recipe.description,
            creator_name=recipe.creator_name,
            source=recipe.source,
            original_url=str(recipe.original_url),
            preparation_minutes=recipe.preparation_minutes,
            cooking_minutes=recipe.cooking_minutes,
            total_minutes=recipe.total_minutes,
            servings=recipe.servings,
            ingredients=[
                TemplateIngredient(
                    quantity_text=value.quantity_text,
                    normalized_quantity=value.normalized_quantity,
                    unit=value.unit,
                    name=value.name,
                    preparation=value.preparation,
                    is_to_taste=False,
                    order_index=value.order_index,
                    uncertainty=value.uncertainty,
                )
                for value in recipe.ingredients
            ],
            steps=[
                TemplateStep(
                    order_index=value.order_index,
                    instruction=value.instruction,
                    ingredient_indexes=[
                        ingredient_indexes[ingredient_id]
                        for ingredient_id in value.ingredient_ids
                    ],
                    timers=[
                        TemplateTimer(
                            label=timer.label,
                            duration_seconds=timer.duration_seconds,
                        )
                        for timer in value.timers
                    ],
                    uncertainty=value.uncertainty,
                )
                for value in recipe.steps
            ],
            nutrition=(
                TemplateNutrition(
                    calories=nutrition.calories,
                    protein_grams=nutrition.protein_grams,
                    carbohydrate_grams=nutrition.carbohydrate_grams,
                    fat_grams=nutrition.fat_grams,
                    saturated_fat_grams=nutrition.saturated_fat_grams,
                    fiber_grams=nutrition.fiber_grams,
                    sugar_grams=nutrition.sugar_grams,
                    sodium_milligrams=nutrition.sodium_milligrams,
                    other_nutrients=[
                        TemplateNutrient(
                            name=value.name,
                            amount=value.amount,
                            unit=value.unit,
                        )
                        for value in nutrition.other_nutrients
                    ],
                    serving_basis=nutrition.serving_basis,
                    is_estimated=nutrition.is_estimated,
                    basis=(
                        "usdaCalculated"
                        if nutrition.is_estimated
                        else "creatorStated"
                    ),
                    evidence=None,
                )
                if nutrition is not None
                else None
            ),
            review_status=recipe.review_status,
            uncertainties=recipe.uncertainties,
        )

    def instantiate(self, *, recipe_id: UUID, now: datetime) -> RecipeDTO:
        ingredient_ids = [uuid4() for _ in self.ingredients]
        nutrition = self.nutrition
        return RecipeDTO(
            id=recipe_id,
            title=self.title,
            description=self.description,
            creator_name=self.creator_name,
            source=self.source,
            original_url=self.original_url,
            images=[],
            preparation_minutes=self.preparation_minutes,
            cooking_minutes=self.cooking_minutes,
            total_minutes=self.total_minutes,
            servings=self.servings,
            ingredients=[
                IngredientDTO(
                    id=ingredient_ids[index],
                    quantity_text=value.quantity_text,
                    normalized_quantity=value.normalized_quantity,
                    unit=value.unit,
                    name=value.name,
                    preparation=value.preparation,
                    order_index=value.order_index,
                    uncertainty=value.uncertainty,
                )
                for index, value in enumerate(self.ingredients)
            ],
            steps=[
                RecipeStepDTO(
                    id=uuid4(),
                    order_index=value.order_index,
                    instruction=value.instruction,
                    ingredient_ids=[
                        ingredient_ids[index] for index in value.ingredient_indexes
                    ],
                    timers=[
                        DetectedTimerDTO(
                            id=uuid4(),
                            label=timer.label,
                            duration_seconds=timer.duration_seconds,
                        )
                        for timer in value.timers
                    ],
                    uncertainty=value.uncertainty,
                )
                for value in self.steps
            ],
            nutrition=(
                NutritionDTO(
                    calories=nutrition.calories,
                    protein_grams=nutrition.protein_grams,
                    carbohydrate_grams=nutrition.carbohydrate_grams,
                    fat_grams=nutrition.fat_grams,
                    saturated_fat_grams=nutrition.saturated_fat_grams,
                    fiber_grams=nutrition.fiber_grams,
                    sugar_grams=nutrition.sugar_grams,
                    sodium_milligrams=nutrition.sodium_milligrams,
                    other_nutrients=[
                        NutrientDTO(
                            id=uuid4(),
                            name=value.name,
                            amount=value.amount,
                            unit=value.unit,
                        )
                        for value in nutrition.other_nutrients
                    ],
                    serving_basis=nutrition.serving_basis,
                    is_estimated=nutrition.is_estimated,
                )
                if nutrition is not None
                else None
            ),
            is_favorite=False,
            review_status=self.review_status,
            uncertainties=self.uncertainties,
            revision=1,
            created_at=now,
            updated_at=now,
        )


class RecipeTemplateCloner:
    def __init__(
        self,
        *,
        clock: Clock,
        reservations: ReservationService,
        repository: RecipeRepository | None = None,
    ) -> None:
        self._clock = clock
        self._reservations = reservations
        self._repository = repository or RecipeRepository()

    def clone_for_job(
        self,
        database: Session,
        *,
        job: ImportJob,
        cache_entry: ExtractionCache,
        template: RecipeTemplate,
    ) -> UUID:
        if job.status in {"ready", "needsReview"} and job.current_recipe_id is not None:
            return job.current_recipe_id

        now = self._clock.now()
        if job.current_recipe_id is not None:
            _, recipe_id = self._complete_reimport(
                database,
                job=job,
                template=template,
                cache_entry=cache_entry,
                now=now,
            )
            database.flush()
            return recipe_id

        recipe_id = uuid4()
        recipe = template.instantiate(recipe_id=recipe_id, now=now)
        stored = self._repository.insert(
            database,
            user_id=job.user_id,
            recipe=recipe,
            created_at=now,
        )
        stored.source_video_id = job.source_video_id
        stored.source_cache_id = cache_entry.id
        self._attach_thumbnail(
            database,
            recipe_id=recipe_id,
            cache_entry=cache_entry,
        )
        self._record_change(
            database,
            user_id=job.user_id,
            recipe_id=recipe_id,
            revision=1,
            changed_at=now,
        )
        self._reservations.consume(database, job.id)
        job.current_recipe_id = recipe_id
        job.cache_entry_id = cache_entry.id
        job.status = cache_entry.review_status
        job.stage = "completed"
        job.completed_at = now
        job.updated_at = now
        database.flush()
        return recipe_id

    def complete_private_for_job(
        self,
        database: Session,
        *,
        job: ImportJob,
        template: RecipeTemplate,
    ) -> bool:
        """Complete a cache-bypassing job; return true when current was promoted."""

        now = self._clock.now()
        if job.current_recipe_id is None:
            recipe_id = uuid4()
            recipe = template.instantiate(recipe_id=recipe_id, now=now)
            stored = self._repository.insert(
                database,
                user_id=job.user_id,
                recipe=recipe,
                created_at=now,
            )
            stored.source_video_id = job.source_video_id
            stored.source_cache_id = None
            self._record_change(
                database,
                user_id=job.user_id,
                recipe_id=recipe_id,
                revision=1,
                changed_at=now,
            )
            self._reservations.consume(database, job.id)
            job.current_recipe_id = recipe_id
            job.candidate_recipe_id = None
            job.status = template.review_status.value
            job.stage = "completed"
            job.completed_at = now
            job.updated_at = now
            self._clear_private_input(job)
            database.flush()
            return True

        promoted, _ = self._complete_reimport(
            database,
            job=job,
            template=template,
            cache_entry=None,
            now=now,
        )
        database.flush()
        return promoted

    def _complete_reimport(
        self,
        database: Session,
        *,
        job: ImportJob,
        template: RecipeTemplate,
        cache_entry: ExtractionCache | None,
        now: datetime,
    ) -> tuple[bool, UUID]:
        if job.current_recipe_id is None:
            raise ValueError("re-import is missing its current recipe")
        current = self._repository.find(
            database,
            user_id=job.user_id,
            recipe_id=job.current_recipe_id,
            include_deleted=True,
        )
        if current is None or current.deleted_at is not None:
            raise ValueError("current recipe is unavailable")

        can_promote = (
            template.review_status == RecipeReviewStatus.READY
            and job.base_recipe_revision is not None
            and current.revision == job.base_recipe_revision
        )
        if can_promote:
            recipe = template.instantiate(recipe_id=current.id, now=now).model_copy(
                update={"is_favorite": current.favorite}
            )
            updated = self._repository.update(
                database,
                stored=current,
                recipe=recipe,
                updated_at=now,
            )
            updated.source_video_id = job.source_video_id
            updated.source_cache_id = (
                cache_entry.id if cache_entry is not None else None
            )
            self._attach_thumbnail(
                database,
                recipe_id=updated.id,
                cache_entry=cache_entry,
            )
            self._record_change(
                database,
                user_id=job.user_id,
                recipe_id=updated.id,
                revision=updated.revision,
                changed_at=now,
            )
            job.candidate_recipe_id = None
            job.cache_entry_id = cache_entry.id if cache_entry is not None else None
            job.status = "ready"
            job.stage = "completed"
            job.completed_at = now
            job.updated_at = now
            self._clear_private_input(job)
            return True, updated.id

        candidate_template = template.model_copy(
            update={"review_status": RecipeReviewStatus.NEEDS_REVIEW}
        )
        candidate_id = uuid4()
        candidate = candidate_template.instantiate(
            recipe_id=candidate_id,
            now=now,
        )
        stored_candidate = self._repository.insert(
            database,
            user_id=job.user_id,
            recipe=candidate,
            created_at=now,
        )
        stored_candidate.source_video_id = job.source_video_id
        stored_candidate.source_cache_id = (
            cache_entry.id if cache_entry is not None else None
        )
        self._attach_thumbnail(
            database,
            recipe_id=candidate_id,
            cache_entry=cache_entry,
        )
        job.candidate_recipe_id = candidate_id
        job.cache_entry_id = cache_entry.id if cache_entry is not None else None
        job.status = "needsReview"
        job.stage = "completed"
        job.completed_at = now
        job.updated_at = now
        self._clear_private_input(job)
        return False, candidate_id

    def _attach_thumbnail(
        self,
        database: Session,
        *,
        recipe_id: UUID,
        cache_entry: ExtractionCache | None,
    ) -> None:
        if cache_entry is None or (
            cache_entry.thumbnail_object_key is None
            and cache_entry.thumbnail_remote_url is None
        ):
            return
        database.add(
            RecipeImage(
                id=uuid4(),
                recipe_id=recipe_id,
                object_key=cache_entry.thumbnail_object_key,
                remote_url=cache_entry.thumbnail_remote_url,
                order_index=0,
            )
        )

    def _clear_private_input(self, job: ImportJob) -> None:
        job.correction_notes_encrypted = None
        job.pasted_text_encrypted = None

    def _record_change(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_id: UUID,
        revision: int,
        changed_at: datetime,
    ) -> None:
        database.add(
            RecipeChange(
                user_id=user_id,
                sequence=allocate_sequence(database, user_id),
                recipe_id=recipe_id,
                kind="upsert",
                recipe_revision=revision,
                changed_at=changed_at,
            )
        )
