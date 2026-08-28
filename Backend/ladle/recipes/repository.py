from collections import defaultdict
from collections.abc import Callable, Collection, Sequence
from datetime import datetime
from decimal import Decimal
from uuid import UUID

from sqlalchemy import delete, distinct, func, select
from sqlalchemy.orm import Session, aliased

from ladle.contracts.recipes import (
    DetectedTimerDTO,
    DiscoverPageDTO,
    DiscoverRecipeDTO,
    FieldUncertaintyDTO,
    IngredientDTO,
    NutrientDTO,
    NutritionDTO,
    RecipeDTO,
    RecipeImageDTO,
    RecipeReviewStatus,
    RecipeSource,
    RecipeStepDTO,
)
from ladle.db.models import (
    DetectedTimer,
    ExtractionCache,
    FieldUncertainty,
    Ingredient,
    Nutrition,
    OtherNutrient,
    Recipe,
    RecipeImage,
    RecipeStep,
    SourceVideo,
    StepIngredient,
)


class ObjectURLUnavailable(Exception):
    pass


class RecipeRepository:
    def __init__(
        self,
        *,
        object_url: Callable[[str], str] | None = None,
    ) -> None:
        self._object_url = object_url

    def find(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_id: UUID,
        include_deleted: bool = False,
        for_update: bool = False,
    ) -> Recipe | None:
        query = select(Recipe).where(
            Recipe.id == recipe_id,
            Recipe.user_id == user_id,
        )
        if not include_deleted:
            query = query.where(Recipe.deleted_at.is_(None))
        if for_update:
            # Callers that then write the row need the read and the write in
            # one atomic step; without the lock two writers pass the same
            # revision check and the second silently overwrites the first.
            query = query.with_for_update()
        return database.scalar(query)

    def find_many(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe_ids: Collection[UUID],
    ) -> dict[UUID, Recipe]:
        """Batch find() for a whole sync page, tombstones included — one
        query instead of one per change row."""
        if not recipe_ids:
            return {}
        stored = database.scalars(
            select(Recipe).where(
                Recipe.id.in_(recipe_ids),
                Recipe.user_id == user_id,
            )
        )
        return {recipe.id: recipe for recipe in stored}

    def discover(
        self,
        database: Session,
        *,
        user_id: UUID,
        limit: int,
    ) -> DiscoverPageDTO:
        saved_recipe = aliased(Recipe)
        saved_source_ids = select(saved_recipe.source_video_id).where(
            saved_recipe.user_id == user_id,
            saved_recipe.source_video_id.is_not(None),
        )
        ranked = database.execute(
            select(
                Recipe.source_video_id,
                func.count(distinct(Recipe.user_id)).label("saved_count"),
                func.max(Recipe.updated_at).label("latest_save"),
            )
            .where(
                Recipe.user_id != user_id,
                Recipe.deleted_at.is_(None),
                Recipe.review_status == RecipeReviewStatus.READY.value,
                Recipe.source != RecipeSource.OTHER.value,
                Recipe.source_video_id.is_not(None),
                Recipe.source_cache_id.is_not(None),
                Recipe.source_video_id.not_in(saved_source_ids),
            )
            .group_by(Recipe.source_video_id)
            .order_by(
                func.count(distinct(Recipe.user_id)).desc(),
                func.max(Recipe.updated_at).desc(),
                Recipe.source_video_id,
            )
            .limit(limit)
        ).all()
        items: list[DiscoverRecipeDTO] = []
        for source_video_id, saved_count, _ in ranked:
            source = database.get(SourceVideo, source_video_id)
            if source is None:
                continue
            cache = database.scalar(
                select(ExtractionCache)
                .where(
                    ExtractionCache.source_video_id == source_video_id,
                    ExtractionCache.source_revision == source.source_revision,
                    ExtractionCache.review_status == RecipeReviewStatus.READY.value,
                    ExtractionCache.invalidated_at.is_(None),
                )
                .order_by(ExtractionCache.created_at.desc(), ExtractionCache.id)
                .limit(1)
            )
            if cache is None:
                continue
            template = cache.template_json
            image_url = self.extraction_thumbnail_url(cache)
            items.append(
                DiscoverRecipeDTO(
                    source_id=source_video_id,
                    title=template["title"],
                    description=template["description"],
                    creator_name=template.get("creatorName"),
                    source=template["source"],
                    original_url=source.canonical_url,
                    image_url=image_url,
                    saved_count=saved_count,
                    saved_recipe_id=None,
                )
            )
        return DiscoverPageDTO(items=items)

    def extraction_thumbnail_url(self, cache: ExtractionCache) -> str | None:
        if cache.thumbnail_remote_url is not None:
            return cache.thumbnail_remote_url
        if cache.thumbnail_object_key is not None and self._object_url is not None:
            return self._object_url(cache.thumbnail_object_key)
        return None

    def insert(
        self,
        database: Session,
        *,
        user_id: UUID,
        recipe: RecipeDTO,
        created_at: datetime,
    ) -> Recipe:
        stored = Recipe(
            id=recipe.id,
            user_id=user_id,
            title=recipe.title,
            description=recipe.description,
            notes=list(recipe.notes),
            creator_name=recipe.creator_name,
            source=recipe.source.value,
            original_url=str(recipe.original_url),
            preparation_minutes=recipe.preparation_minutes,
            cooking_minutes=recipe.cooking_minutes,
            total_minutes=recipe.total_minutes,
            servings=recipe.servings,
            favorite=recipe.is_favorite,
            review_status=recipe.review_status.value,
            revision=1,
            created_at=created_at,
            updated_at=created_at,
        )
        database.add(stored)
        database.flush()
        self.replace_graph(database, stored=stored, recipe=recipe)
        return stored

    def update(
        self,
        database: Session,
        *,
        stored: Recipe,
        recipe: RecipeDTO,
        updated_at: datetime,
    ) -> Recipe:
        stored.title = recipe.title
        stored.description = recipe.description
        stored.creator_name = recipe.creator_name
        stored.source = recipe.source.value
        stored.original_url = str(recipe.original_url)
        stored.preparation_minutes = recipe.preparation_minutes
        stored.cooking_minutes = recipe.cooking_minutes
        stored.total_minutes = recipe.total_minutes
        stored.servings = recipe.servings
        stored.favorite = recipe.is_favorite
        stored.review_status = recipe.review_status.value
        stored.revision += 1
        stored.updated_at = updated_at
        self.replace_graph(database, stored=stored, recipe=recipe)
        return stored

    def replace_graph(
        self,
        database: Session,
        *,
        stored: Recipe,
        recipe: RecipeDTO,
    ) -> None:
        # An image's location is rendered on the way out — an object-storage
        # image leaves as a short-lived presigned URL — so the value coming
        # back in cannot be trusted as its location. Keep what is stored for
        # images the recipe already had; only a genuinely new image is
        # located by the URL the client supplied.
        stored_locations = {
            image_id: (object_key, remote_url)
            for image_id, object_key, remote_url in database.execute(
                select(
                    RecipeImage.id,
                    RecipeImage.object_key,
                    RecipeImage.remote_url,
                ).where(RecipeImage.recipe_id == stored.id)
            )
        }
        self._delete_graph(database, stored.id)

        database.add_all(
            self._replacement_image(
                recipe_id=stored.id,
                image=image,
                order_index=index,
                stored_locations=stored_locations,
            )
            for index, image in enumerate(recipe.images)
        )
        database.add_all(
            Ingredient(
                id=ingredient.id,
                recipe_id=stored.id,
                quantity_text=ingredient.quantity_text,
                normalized_quantity=ingredient.normalized_quantity,
                unit=ingredient.unit,
                name=ingredient.name,
                preparation=ingredient.preparation,
                order_index=ingredient.order_index,
            )
            for ingredient in recipe.ingredients
        )
        database.add_all(
            RecipeStep(
                id=step.id,
                recipe_id=stored.id,
                order_index=step.order_index,
                instruction=step.instruction,
                source_start_seconds=step.source_start_seconds,
                source_end_seconds=step.source_end_seconds,
            )
            for step in recipe.steps
        )
        database.flush()

        for step in recipe.steps:
            database.add_all(
                StepIngredient(
                    recipe_id=stored.id,
                    step_id=step.id,
                    ingredient_id=ingredient_id,
                )
                for ingredient_id in step.ingredient_ids
            )
            database.add_all(
                DetectedTimer(
                    id=timer.id,
                    recipe_step_id=step.id,
                    label=timer.label,
                    duration_seconds=timer.duration_seconds,
                )
                for timer in step.timers
            )
            if step.uncertainty is not None:
                database.add(
                    self._stored_uncertainty(
                        stored.id,
                        step.uncertainty,
                        step_id=step.id,
                    )
                )

        for ingredient in recipe.ingredients:
            if ingredient.uncertainty is not None:
                database.add(
                    self._stored_uncertainty(
                        stored.id,
                        ingredient.uncertainty,
                        ingredient_id=ingredient.id,
                    )
                )

        database.add_all(
            self._stored_uncertainty(stored.id, uncertainty)
            for uncertainty in recipe.uncertainties
        )

        if recipe.nutrition is not None:
            nutrition = recipe.nutrition
            database.add(
                Nutrition(
                    recipe_id=stored.id,
                    calories=nutrition.calories,
                    protein_grams=nutrition.protein_grams,
                    carbohydrate_grams=nutrition.carbohydrate_grams,
                    fat_grams=nutrition.fat_grams,
                    saturated_fat_grams=nutrition.saturated_fat_grams,
                    fiber_grams=nutrition.fiber_grams,
                    sugar_grams=nutrition.sugar_grams,
                    sodium_milligrams=nutrition.sodium_milligrams,
                    serving_basis=nutrition.serving_basis,
                    is_estimated=nutrition.is_estimated,
                )
            )
            database.flush()
            database.add_all(
                OtherNutrient(
                    id=nutrient.id,
                    nutrition_recipe_id=stored.id,
                    name=nutrient.name,
                    amount=nutrient.amount,
                    unit=nutrient.unit,
                )
                for nutrient in nutrition.other_nutrients
            )

    def to_dto(self, database: Session, stored: Recipe) -> RecipeDTO:
        return self.to_dtos(database, [stored])[stored.id]

    def to_dtos(
        self,
        database: Session,
        recipes: Sequence[Recipe],
    ) -> dict[UUID, RecipeDTO]:
        """Materialise many recipes with one query per child table instead
        of eight queries per recipe — a sync page renders through here, so
        its cost must stay flat in the page size."""
        if not recipes:
            return {}
        recipe_ids = [stored.id for stored in recipes]
        images: dict[UUID, list[RecipeImage]] = defaultdict(list)
        for image in database.scalars(
            select(RecipeImage)
            .where(RecipeImage.recipe_id.in_(recipe_ids))
            .order_by(RecipeImage.recipe_id, RecipeImage.order_index)
        ):
            images[image.recipe_id].append(image)
        ingredients: dict[UUID, list[Ingredient]] = defaultdict(list)
        for ingredient in database.scalars(
            select(Ingredient)
            .where(Ingredient.recipe_id.in_(recipe_ids))
            .order_by(Ingredient.recipe_id, Ingredient.order_index, Ingredient.id)
        ):
            ingredients[ingredient.recipe_id].append(ingredient)
        steps: dict[UUID, list[RecipeStep]] = defaultdict(list)
        for step in database.scalars(
            select(RecipeStep)
            .where(RecipeStep.recipe_id.in_(recipe_ids))
            .order_by(RecipeStep.recipe_id, RecipeStep.order_index, RecipeStep.id)
        ):
            steps[step.recipe_id].append(step)
        links_by_step: dict[UUID, list[UUID]] = defaultdict(list)
        for link in database.scalars(
            select(StepIngredient).where(StepIngredient.recipe_id.in_(recipe_ids))
        ):
            links_by_step[link.step_id].append(link.ingredient_id)
        timers_by_step: dict[UUID, list[DetectedTimer]] = defaultdict(list)
        step_ids = [step.id for value in steps.values() for step in value]
        if step_ids:
            for timer in database.scalars(
                select(DetectedTimer).where(DetectedTimer.recipe_step_id.in_(step_ids))
            ):
                timers_by_step[timer.recipe_step_id].append(timer)
        uncertainties: dict[UUID, list[FieldUncertainty]] = defaultdict(list)
        for value in database.scalars(
            select(FieldUncertainty).where(FieldUncertainty.recipe_id.in_(recipe_ids))
        ):
            uncertainties[value.recipe_id].append(value)
        nutrition = {
            row.recipe_id: row
            for row in database.scalars(
                select(Nutrition).where(Nutrition.recipe_id.in_(recipe_ids))
            )
        }
        other_nutrients: dict[UUID, list[OtherNutrient]] = defaultdict(list)
        for nutrient in database.scalars(
            select(OtherNutrient).where(
                OtherNutrient.nutrition_recipe_id.in_(recipe_ids)
            )
        ):
            other_nutrients[nutrient.nutrition_recipe_id].append(nutrient)
        return {
            stored.id: self._dto(
                stored,
                images=images[stored.id],
                ingredients=ingredients[stored.id],
                steps=steps[stored.id],
                links_by_step=links_by_step,
                timers_by_step=timers_by_step,
                uncertainties=uncertainties[stored.id],
                nutrition=nutrition.get(stored.id),
                other_nutrients=other_nutrients[stored.id],
            )
            for stored in recipes
        }

    def _dto(
        self,
        stored: Recipe,
        *,
        images: list[RecipeImage],
        ingredients: list[Ingredient],
        steps: list[RecipeStep],
        links_by_step: dict[UUID, list[UUID]],
        timers_by_step: dict[UUID, list[DetectedTimer]],
        uncertainties: list[FieldUncertainty],
        nutrition: Nutrition | None,
        other_nutrients: list[OtherNutrient],
    ) -> RecipeDTO:
        ingredient_uncertainty = {
            value.ingredient_id: value
            for value in uncertainties
            if value.ingredient_id is not None
        }
        step_uncertainty = {
            value.step_id: value for value in uncertainties if value.step_id is not None
        }

        return RecipeDTO(
            id=stored.id,
            title=stored.title,
            description=stored.description,
            notes=list(stored.notes or []),
            creator_name=stored.creator_name,
            source=RecipeSource(stored.source),
            original_url=stored.original_url,
            images=[
                RecipeImageDTO(id=image.id, remote_url=self._image_url(image))
                for image in images
            ],
            preparation_minutes=stored.preparation_minutes,
            cooking_minutes=stored.cooking_minutes,
            total_minutes=stored.total_minutes,
            servings=stored.servings,
            ingredients=[
                IngredientDTO(
                    id=ingredient.id,
                    quantity_text=ingredient.quantity_text,
                    normalized_quantity=ingredient.normalized_quantity,
                    unit=ingredient.unit,
                    name=ingredient.name,
                    preparation=ingredient.preparation,
                    order_index=ingredient.order_index,
                    uncertainty=self._uncertainty_dto(
                        ingredient_uncertainty.get(ingredient.id)
                    ),
                )
                for ingredient in ingredients
            ],
            steps=[
                RecipeStepDTO(
                    id=step.id,
                    order_index=step.order_index,
                    instruction=step.instruction,
                    ingredient_ids=links_by_step.get(step.id, []),
                    source_start_seconds=step.source_start_seconds,
                    source_end_seconds=step.source_end_seconds,
                    timers=[
                        DetectedTimerDTO(
                            id=timer.id,
                            label=timer.label,
                            duration_seconds=timer.duration_seconds,
                        )
                        for timer in timers_by_step.get(step.id, [])
                    ],
                    uncertainty=self._uncertainty_dto(step_uncertainty.get(step.id)),
                )
                for step in steps
            ],
            nutrition=self._nutrition_dto(nutrition, other_nutrients),
            is_favorite=stored.favorite,
            review_status=RecipeReviewStatus(stored.review_status),
            uncertainties=[
                self._uncertainty_dto(value)
                for value in uncertainties
                if value.ingredient_id is None and value.step_id is None
            ],
            revision=stored.revision,
            created_at=stored.created_at,
            updated_at=stored.updated_at,
        )

    @staticmethod
    def _replacement_image(
        *,
        recipe_id: UUID,
        image: RecipeImageDTO,
        order_index: int,
        stored_locations: dict[UUID, tuple[str | None, str | None]],
    ) -> RecipeImage:
        object_key, remote_url = stored_locations.get(image.id, (None, None))
        if object_key is None and remote_url is None:
            remote_url = str(image.remote_url)
        return RecipeImage(
            id=image.id,
            recipe_id=recipe_id,
            object_key=object_key,
            remote_url=remote_url,
            order_index=order_index,
        )

    def _delete_graph(self, database: Session, recipe_id: UUID) -> None:
        step_ids = select(RecipeStep.id).where(RecipeStep.recipe_id == recipe_id)
        database.execute(
            delete(FieldUncertainty).where(FieldUncertainty.recipe_id == recipe_id)
        )
        database.execute(
            delete(DetectedTimer).where(DetectedTimer.recipe_step_id.in_(step_ids))
        )
        database.execute(
            delete(StepIngredient).where(StepIngredient.recipe_id == recipe_id)
        )
        database.execute(delete(RecipeStep).where(RecipeStep.recipe_id == recipe_id))
        database.execute(delete(Ingredient).where(Ingredient.recipe_id == recipe_id))
        database.execute(delete(RecipeImage).where(RecipeImage.recipe_id == recipe_id))
        database.execute(
            delete(OtherNutrient).where(OtherNutrient.nutrition_recipe_id == recipe_id)
        )
        database.execute(delete(Nutrition).where(Nutrition.recipe_id == recipe_id))
        database.flush()

    def _stored_uncertainty(
        self,
        recipe_id: UUID,
        value: FieldUncertaintyDTO,
        *,
        ingredient_id: UUID | None = None,
        step_id: UUID | None = None,
    ) -> FieldUncertainty:
        return FieldUncertainty(
            recipe_id=recipe_id,
            ingredient_id=ingredient_id,
            step_id=step_id,
            field=value.field,
            reason=value.reason,
            confidence=(
                Decimal(str(value.confidence)) if value.confidence is not None else None
            ),
        )

    def _uncertainty_dto(
        self,
        value: FieldUncertainty | None,
    ) -> FieldUncertaintyDTO | None:
        if value is None:
            return None
        return FieldUncertaintyDTO(
            field=value.field,
            reason=value.reason,
            confidence=float(value.confidence)
            if value.confidence is not None
            else None,
        )

    def _nutrition_dto(
        self,
        nutrition: Nutrition | None,
        others: list[OtherNutrient],
    ) -> NutritionDTO | None:
        if nutrition is None:
            return None
        return NutritionDTO(
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
                    id=value.id,
                    name=value.name,
                    amount=value.amount,
                    unit=value.unit,
                )
                for value in others
            ],
            serving_basis=nutrition.serving_basis,
            is_estimated=nutrition.is_estimated,
        )

    def _image_url(self, image: RecipeImage) -> str:
        if image.remote_url is not None:
            return image.remote_url
        if image.object_key is not None and self._object_url is not None:
            return self._object_url(image.object_key)
        raise ObjectURLUnavailable
