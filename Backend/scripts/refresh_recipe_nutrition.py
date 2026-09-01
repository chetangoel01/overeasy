"""Recalculate nutrition for recipes already in the database, in place.

Reimporting a recipe creates a second copy of it and leaves the original
behind, which is the wrong tool for "these recipes should have calories now".
This re-runs only the nutrition step — normalization and the USDA calculation —
against the recipe as it already exists, and writes the result onto that same
row. Titles, steps, ingredients, edits and identifiers are untouched.

Dry run by default: it prints what each recipe would become and changes
nothing. Pass --apply to write.

    python scripts/refresh_recipe_nutrition.py --user-id <uuid>
    python scripts/refresh_recipe_nutrition.py --user-id <uuid> --apply
"""

from __future__ import annotations

import argparse
from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import httpx
from sqlalchemy import delete, select
from sqlalchemy.orm import Session

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor
from ladle.config import Settings
from ladle.db.models import (
    FieldUncertainty,
    Nutrition,
    OtherNutrient,
    Recipe,
    RecipeChange,
    SourceVideo,
)
from ladle.db.session import build_engine, build_session_factory
from ladle.nutrition.calculator import NutritionCalculator
from ladle.nutrition.normalization import (
    OpenRouterNutritionNormalizationClient,
    RecipeNutritionNormalizer,
)
from ladle.nutrition.service import RecipeNutritionService
from ladle.nutrition.store import DatabaseUSDAPayloadStore
from ladle.nutrition.usda import USDAClient
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.template_clone import RecipeTemplate
from ladle.sync.sequence import allocate_sequence

#: Fields this script owns. Everything else a recipe carries — amount
#: estimates, yield rationale — belongs to the original import and is left
#: alone.
_OWNED_FIELDS = ("nutrition",)
_OWNED_SUFFIX = ".nutritionMatch"


def _service(settings: Settings, sessions) -> RecipeNutritionService:
    assert settings.usda_api_key is not None
    assert settings.openrouter_api_key is not None
    return RecipeNutritionService(
        normalizer=RecipeNutritionNormalizer(
            client=OpenRouterNutritionNormalizationClient(
                http=httpx.Client(
                    timeout=settings.openrouter_timeout_seconds, trust_env=False
                ),
                api_key=settings.openrouter_api_key.get_secret_value(),
                base_url=str(settings.openrouter_base_url),
            ),
            model_id=settings.nutrition_normalization_model_id,
            max_tokens=settings.nutrition_normalization_max_tokens,
        ),
        calculator=NutritionCalculator(
            USDAClient(
                http=httpx.Client(
                    timeout=settings.usda_timeout_seconds, trust_env=False
                ),
                api_key=settings.usda_api_key.get_secret_value(),
                base_url=str(settings.usda_base_url),
                maximum_candidates=settings.usda_maximum_candidates,
                store=DatabaseUSDAPayloadStore(session_factory=sessions),
            )
        ),
    )


def _context(
    template: RecipeTemplate,
    source: SourceVideo,
) -> AcquiredVideoContext:
    """The recipe standing in for the video it came from.

    The original transcript is not kept once a recipe exists, and nutrition
    does not need it: quantities and ingredient names are on the recipe, and
    those are what the normalizer converts to grams.
    """
    return AcquiredVideoContext(
        source=SourceVideoDescriptor.from_stored(source),
        is_public=True,
        title=template.title,
        description=template.description,
        creator_name=template.creator_name,
    )


def _announce(database: Session, stored: Recipe) -> None:
    """Tell every client the recipe changed.

    Sync is a change log: a client pulls `RecipeChange` rows after its cursor,
    so a write that does not append one is invisible no matter how correct the
    data is. The first version of this script replaced nutrition without
    announcing it, and seventeen recipes carried new numbers that no device
    ever asked for. This mirrors `RecipeService`'s own mutation exactly — one
    timestamp shared by the row and the change, the revision incremented
    first, and the change carrying that new revision.
    """
    now = datetime.now(UTC)
    stored.updated_at = now
    stored.revision += 1
    database.add(
        RecipeChange(
            user_id=stored.user_id,
            sequence=allocate_sequence(database, stored.user_id),
            recipe_id=stored.id,
            kind="upsert",
            recipe_revision=stored.revision,
            changed_at=now,
        )
    )


def _replace_nutrition(
    database: Session,
    recipe_id: UUID,
    template: RecipeTemplate,
) -> None:
    database.execute(
        delete(OtherNutrient).where(OtherNutrient.nutrition_recipe_id == recipe_id)
    )
    database.execute(delete(Nutrition).where(Nutrition.recipe_id == recipe_id))
    for row in database.scalars(
        select(FieldUncertainty).where(FieldUncertainty.recipe_id == recipe_id)
    ).all():
        if row.field in _OWNED_FIELDS or row.field.endswith(_OWNED_SUFFIX):
            database.delete(row)

    value = template.nutrition
    if value is not None:
        database.add(
            Nutrition(
                recipe_id=recipe_id,
                calories=value.calories,
                protein_grams=value.protein_grams,
                carbohydrate_grams=value.carbohydrate_grams,
                fat_grams=value.fat_grams,
                saturated_fat_grams=value.saturated_fat_grams,
                fiber_grams=value.fiber_grams,
                sugar_grams=value.sugar_grams,
                sodium_milligrams=value.sodium_milligrams,
                serving_basis=value.serving_basis,
                is_estimated=value.is_estimated,
            )
        )
    for uncertainty in template.uncertainties:
        if uncertainty.field in _OWNED_FIELDS or uncertainty.field.endswith(
            _OWNED_SUFFIX
        ):
            database.add(
                FieldUncertainty(
                    recipe_id=recipe_id,
                    field=uncertainty.field,
                    reason=uncertainty.reason,
                )
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--user-id", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument(
        "--announce-only",
        action="store_true",
        help=(
            "Skip enrichment and only re-announce what is already stored. "
            "For recipes whose nutrition was written before this script "
            "recorded change-log rows: it makes them visible to clients "
            "without recomputing, so the numbers do not move."
        ),
    )
    args = parser.parse_args()

    settings = Settings()
    engine = build_engine(str(settings.database_url))
    sessions = build_session_factory(engine)
    # Announcing needs no provider credentials — it recomputes nothing.
    service = None if args.announce_only else _service(settings, sessions)
    # Thumbnails need a signed object URL that only the API process is set up
    # to mint, and nutrition does not look at images. A placeholder keeps the
    # DTO buildable without dragging object storage into this.
    repository = RecipeRepository(
        object_url=lambda key: f"https://placeholder.invalid/{key}"
    )

    with sessions() as database:
        stored_recipes = database.scalars(
            select(Recipe)
            .where(
                Recipe.user_id == UUID(args.user_id),
                Recipe.deleted_at.is_(None),
            )
            .order_by(Recipe.created_at)
        ).all()
        print(f"{len(stored_recipes)} recipes\n")

        changed = 0
        for position, stored in enumerate(stored_recipes, start=1):
            source = (
                database.get(SourceVideo, stored.source_video_id)
                if stored.source_video_id is not None
                else None
            )
            if source is None:
                print(f"{position:2}. {stored.title[:38]:40} no source video, skipped")
                continue
            dto = repository.to_dto(database, stored)
            before = dto.nutrition.calories if dto.nutrition else None
            if args.announce_only:
                print(
                    f"{position:2}. {dto.title[:38]:40} "
                    f"{_calories(before)}, revision {stored.revision}"
                )
                if args.apply:
                    _announce(database, stored)
                    database.commit()
                    changed += 1
                continue
            template = RecipeTemplate.from_recipe(dto)
            if template.nutrition is not None and (
                template.nutrition.basis == "creatorStated"
            ):
                print(f"{position:2}. {dto.title[:38]:40} creator-stated, left alone")
                continue
            # Clear it so a stale value cannot survive as the answer.
            template = template.model_copy(update={"nutrition": None})

            try:
                enriched = service.enrich(
                    template, context=_context(template, source), job_id=uuid4()
                )
            except Exception as error:
                print(f"{position:2}. {dto.title[:38]:40} FAILED {error}")
                continue

            after = enriched.nutrition.calories if enriched.nutrition else None
            weak = [
                value.reason
                for value in enriched.uncertainties
                if value.field.endswith(_OWNED_SUFFIX)
            ]
            blocked = next(
                (
                    value.reason
                    for value in enriched.uncertainties
                    if value.field == "nutrition"
                ),
                None,
            )
            arrow = f"{_calories(before)} -> {_calories(after)}"
            print(f"{position:2}. {dto.title[:38]:40} {arrow}")
            if blocked:
                print(f"    {blocked}")
            for reason in weak:
                print(f"    weak: {reason}")

            if args.apply:
                _replace_nutrition(database, stored.id, enriched)
                _announce(database, stored)
                database.commit()
                changed += 1

        print()
        verb = "applied to" if args.apply else "dry run over"
        print(f"{verb} {changed if args.apply else len(stored_recipes)} recipes")
    return 0


def _calories(value: Decimal | None) -> str:
    return "none" if value is None else f"{value:.0f} kcal"


if __name__ == "__main__":
    raise SystemExit(main())
