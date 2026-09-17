"""Give already-imported recipes the total time the new prompt would give them.

The extraction cache is keyed on the prompt version, so a prompt that now
estimates a total does nothing for recipes already in the library: they keep
their "—" until every source is imported again. This asks the configured
extraction provider the timing question on its own, against what is already
stored — title, the creator's caption, ingredients, ordered steps with their
timers, any stated preparation and cooking time — with no re-extraction and
no transcript.

The answer is written through the path a cook's own edit takes, so the
revision bumps and the change reaches the device's next sync page. A row
updated in place would never arrive.

    python -m ladle.admin.backfill_times --dry-run
    python -m ladle.admin.backfill_times --limit 5
"""

import argparse
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from datetime import timedelta
from uuid import UUID

import anthropic
import httpx
from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.contracts.recipes import (
    FieldUncertaintyDTO,
)
from ladle.db.models import ExtractionCache, Recipe, SourceVideo
from ladle.db.session import build_engine, build_session_factory
from ladle.extraction.review import ESTIMATED_TOTAL_REASON
from ladle.extraction.timing import (
    AnthropicTimeEstimateClient,
    OpenRouterTimeEstimateClient,
    TimeEstimateClient,
    step_timer_minutes,
    time_evidence,
)
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService, SyncConflict
from ladle.recipes.template_clone import RecipeTemplate
from ladle.worker.runtime import runtime_object_storage

_PAUSE_SECONDS = 1.0


@dataclass(frozen=True)
class BackfillRow:
    """One line of the table, printed identically dry or wet."""

    recipe_id: UUID
    title: str
    creator_name: str | None
    preparation_minutes: int | None
    cooking_minutes: int | None
    timer_minutes: int
    proposed_minutes: int | None
    action: str
    kind: str = "recipe"


class TimeBackfillService:
    def __init__(
        self,
        *,
        client: TimeEstimateClient,
        model_id: str,
        max_tokens: int,
        recipes: RecipeService,
        repository: RecipeRepository,
        pause_seconds: float = _PAUSE_SECONDS,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._client = client
        self._model_id = model_id
        self._max_tokens = max_tokens
        self._recipes = recipes
        self._repository = repository
        self._pause_seconds = pause_seconds
        self._sleep = sleep

    def run(
        self,
        database: Session,
        *,
        limit: int | None,
        dry_run: bool,
    ) -> list[BackfillRow]:
        query = (
            select(Recipe)
            .where(Recipe.deleted_at.is_(None), Recipe.total_minutes.is_(None))
            .order_by(Recipe.created_at, Recipe.id)
        )
        if limit is not None:
            query = query.limit(limit)
        rows: list[BackfillRow] = []
        for index, stored in enumerate(database.scalars(query).all()):
            if index and self._pause_seconds > 0:
                # A library-sized run fired as fast as the loop could go was
                # rate limited two thirds of the way through. A second between
                # recipes costs half a minute and keeps the run in one pass.
                self._sleep(self._pause_seconds)
            rows.append(self._one(database, stored, dry_run=dry_run))
        # Repair shared templates from their own public content, never from
        # a saver's potentially edited copy. Future saves then inherit time.
        caches = database.scalars(
            select(ExtractionCache)
            .join(SourceVideo)
            .where(
                ExtractionCache.invalidated_at.is_(None),
                ExtractionCache.source_revision == SourceVideo.source_revision,
            )
            .order_by(ExtractionCache.created_at, ExtractionCache.id)
            .with_for_update(of=ExtractionCache)
        )
        for cached in caches:
            if limit is not None and len(rows) >= limit:
                break
            if (
                RecipeTemplate.model_validate(cached.template_json).total_minutes
                is not None
            ):
                continue
            if rows and self._pause_seconds > 0:
                self._sleep(self._pause_seconds)
            rows.append(self._one(database, cached, dry_run=dry_run))
        return rows

    def _one(
        self,
        database: Session,
        stored: Recipe | ExtractionCache,
        *,
        dry_run: bool,
    ) -> BackfillRow:
        recipe = (
            RecipeTemplate.model_validate(stored.template_json).instantiate(
                recipe_id=stored.id,
                now=stored.created_at,
            )
            if isinstance(stored, ExtractionCache)
            else self._repository.to_dto(database, stored)
        )
        timer_minutes = step_timer_minutes(recipe.steps)
        floor = max(
            timer_minutes,
            (recipe.preparation_minutes or 0) + (recipe.cooking_minutes or 0),
        )

        def row(proposed: int | None, action: str) -> BackfillRow:
            return BackfillRow(
                recipe_id=recipe.id,
                title=recipe.title,
                creator_name=recipe.creator_name,
                preparation_minutes=recipe.preparation_minutes,
                cooking_minutes=recipe.cooking_minutes,
                timer_minutes=timer_minutes,
                proposed_minutes=proposed,
                action=action,
                kind="template" if isinstance(stored, ExtractionCache) else "recipe",
            )

        outcome = self._client.estimate(
            model=self._model_id,
            max_tokens=self._max_tokens,
            evidence=time_evidence(recipe),
        )
        estimate = outcome.estimate
        if estimate is None:
            return row(None, f"skipped: {outcome.failure or 'no estimate in reply'}")
        if estimate.total_minutes < floor:
            # A total under the recipe's own timers is not conservative, it
            # is wrong. Better an empty field than a figure the cook would
            # plan an evening around.
            bound = (
                f"timer sum ({floor} min)"
                if floor == timer_minutes
                else f"stated prep + cook ({floor} min)"
            )
            return row(estimate.total_minutes, f"skipped: below {bound}")
        if dry_run:
            return row(
                estimate.total_minutes, f"would set {estimate.total_minutes} min"
            )

        uncertainties = list(recipe.uncertainties)
        if all(value.field != "total_minutes" for value in uncertainties):
            uncertainties.append(
                FieldUncertaintyDTO(
                    field="total_minutes",
                    reason=ESTIMATED_TOTAL_REASON,
                )
            )
        if isinstance(stored, ExtractionCache):
            stored.template_json = {
                **stored.template_json,
                "totalMinutes": estimate.total_minutes,
                "uncertainties": [
                    u.model_dump(mode="json", by_alias=True) for u in uncertainties
                ],
            }
            return row(estimate.total_minutes, f"set {estimate.total_minutes} min")
        try:
            self._recipes.upsert(
                database,
                user_id=stored.user_id,
                # review_status is carried through untouched: an estimate is
                # a caveat beside the total, not a reason to check the recipe.
                recipe=recipe.model_copy(
                    update={
                        "total_minutes": estimate.total_minutes,
                        "uncertainties": uncertainties,
                    }
                ),
                base_revision=stored.revision,
            )
        except SyncConflict:
            return row(estimate.total_minutes, "skipped: edited during the run")
        return row(estimate.total_minutes, f"set {estimate.total_minutes} min")


_COLUMNS = ("kind", "recipe", "creator", "prep", "cook", "timers", "proposed", "action")


def render_table(rows: Sequence[BackfillRow]) -> str:
    if not rows:
        return "No recipes are missing a total time."
    body = [
        (
            row.kind,
            row.title[:40],
            (row.creator_name or "—")[:20],
            _minutes(row.preparation_minutes),
            _minutes(row.cooking_minutes),
            f"{row.timer_minutes} min" if row.timer_minutes else "—",
            _minutes(row.proposed_minutes),
            row.action,
        )
        for row in rows
    ]
    widths = [
        max(len(heading), *(len(line[index]) for line in body))
        for index, heading in enumerate(_COLUMNS)
    ]
    lines = [
        "  ".join(
            value.ljust(width) for value, width in zip(_COLUMNS, widths, strict=True)
        ).rstrip(),
        "  ".join("-" * width for width in widths),
    ]
    lines.extend(
        "  ".join(
            value.ljust(width) for value, width in zip(line, widths, strict=True)
        ).rstrip()
        for line in body
    )
    return "\n".join(lines)


def _minutes(value: int | None) -> str:
    return "—" if value is None else f"{value} min"


def build_service(settings: Settings) -> TimeBackfillService:
    """The provider the import worker would use, asked a narrower question."""

    client: TimeEstimateClient
    if settings.extraction_provider == "openrouter":
        if settings.openrouter_api_key is None:
            raise RuntimeError("the time backfill requires an OpenRouter API key")
        client = OpenRouterTimeEstimateClient(
            http=httpx.Client(
                timeout=settings.openrouter_timeout_seconds,
                trust_env=False,
            ),
            api_key=settings.openrouter_api_key.get_secret_value(),
            base_url=str(settings.openrouter_base_url),
        )
        model_id = settings.openrouter_model_id
    else:
        if settings.anthropic_api_key is None:
            raise RuntimeError("the time backfill requires an Anthropic API key")
        client = AnthropicTimeEstimateClient(
            anthropic.Anthropic(
                api_key=settings.anthropic_api_key.get_secret_value(),
                base_url=str(settings.anthropic_base_url),
                timeout=settings.anthropic_timeout_seconds,
                # The SDK retries twice on its own by default, which under the
                # loop above would spend nine requests on a persistent 429.
                # The outer loop is the single retry policy.
                max_retries=0,
            )
        )
        model_id = settings.anthropic_model_id

    storage = runtime_object_storage()
    object_url: Callable[[str], str] | None = None
    if storage is not None:
        signing = storage

        def object_url(key: str) -> str:
            return signing.signed_read_url(key, expires_in=timedelta(hours=6))

    repository = RecipeRepository(object_url=object_url)
    return TimeBackfillService(
        client=client,
        model_id=model_id,
        max_tokens=settings.recipe_verification_max_tokens,
        recipes=RecipeService(clock=SystemClock(), repository=repository),
        repository=repository,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Estimate a total cooking time for recipes that carry none",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="ask the provider and print the table without writing anything",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="stop after this many recipes and shared templates",
    )
    arguments = parser.parse_args(argv)
    limit: int | None = arguments.limit
    dry_run: bool = arguments.dry_run
    if limit is not None and limit < 1:
        parser.error("--limit must be at least 1")

    settings = Settings()
    sessions = build_session_factory(build_engine(settings.database_url))
    service = build_service(settings)
    with sessions() as database:
        rows = service.run(database, limit=limit, dry_run=dry_run)
        if dry_run:
            database.rollback()
        else:
            database.commit()
    print(render_table(rows))
    written = sum(1 for row in rows if row.action.startswith("set "))
    print(
        f"\n{len(rows)} recipes/templates considered, "
        f"{written} written{' (dry run)' if dry_run else ''}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
