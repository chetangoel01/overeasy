"""Give already-imported recipes the tags the new prompt would give them.

The extraction cache is keyed on the prompt version, so a prompt that now
asks what a dish is does nothing for a library already imported: every stored
recipe stays untagged, and a diet filter over an untagged corpus is an empty
app. This re-acquires each source and re-runs the whole extraction against it,
because that is where the evidence lives — the caption and the transcript are
what say whether a dish is vegan, and they are not in the stored recipe.

Only the tags are written back. The rest of the fresh extraction is thrown
away: a cook's own title, their edited quantities and their notes are theirs,
and a backfill that quietly replaced them with a second opinion would be a
data loss dressed as an improvement. The write goes through the path an edit
takes, so the revision bumps and the change reaches the device's next sync
page; a row updated in place would never arrive.

One acquisition per source, not per recipe: several cooks save the same video
and they all get the same answer, so paying for it once is the difference
between a cheap run and an expensive one.

    python -m ladle.admin.backfill_tags --dry-run
    python -m ladle.admin.backfill_tags --limit 5

Run it against the local stack first. `LADLE_WORKER_PROVIDER_MODE=fake` uses
the deterministic fake provider, which exercises every step of the command
without a paid call.
"""

import argparse
import logging
import time
from collections.abc import Callable, Sequence
from dataclasses import dataclass, replace
from datetime import timedelta
from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.acquisition.errors import AcquisitionError
from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.protocol import VideoAcquirer
from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.db.models import Recipe, SourceVideo
from ladle.db.session import build_engine, build_session_factory
from ladle.extraction.claude import ExtractionUnavailable
from ladle.extraction.protocol import RecipeExtractor
from ladle.recipes.repository import RecipeRepository
from ladle.recipes.service import RecipeService, SyncConflict
from ladle.recipes.template_clone import RecipeTemplate
from ladle.usage.ledger import NullProviderUsageSink
from ladle.worker.runtime import (
    FakeRuntimeAcquirer,
    FakeRuntimeExtractor,
    runtime_acquirer,
    runtime_extractor,
    runtime_metrics,
    runtime_object_storage,
)

LOGGER = logging.getLogger(__name__)

#: Between sources, not between recipes: the providers are rate limited per
#: request and several savers of one video cost one request.
_PAUSE_SECONDS = 1.0


@dataclass(frozen=True)
class BackfillRow:
    """One line of the table, printed identically dry or wet."""

    recipe_id: UUID
    title: str
    creator_name: str | None
    diets: tuple[str, ...] = ()
    cuisines: tuple[str, ...] = ()
    keywords: tuple[str, ...] = ()
    proposals: tuple[str, ...] = ()
    action: str = ""


class TagBackfillService:
    def __init__(
        self,
        *,
        acquirer: VideoAcquirer,
        extractor: RecipeExtractor,
        recipes: RecipeService,
        repository: RecipeRepository,
        pause_seconds: float = _PAUSE_SECONDS,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._acquirer = acquirer
        self._extractor = extractor
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
        """`limit` counts sources, because a source is what costs money."""

        rows: list[BackfillRow] = []
        for index, source_id in enumerate(self._sources(database, limit=limit)):
            if index and self._pause_seconds > 0:
                self._sleep(self._pause_seconds)
            rows.extend(self._one_source(database, source_id, dry_run=dry_run))
        rows.extend(self._untagged_manual_recipes(database))
        return rows

    def _sources(self, database: Session, *, limit: int | None) -> list[UUID]:
        query = (
            select(Recipe.source_video_id)
            .where(
                Recipe.deleted_at.is_(None),
                Recipe.source_video_id.is_not(None),
            )
            .group_by(Recipe.source_video_id)
            # Oldest source first, so a run stopped by --limit resumes where a
            # reader of the table would expect it to.
            .order_by(Recipe.source_video_id)
        )
        if limit is not None:
            query = query.limit(limit)
        return [value for value in database.scalars(query) if value is not None]

    def _one_source(
        self,
        database: Session,
        source_id: UUID,
        *,
        dry_run: bool,
    ) -> list[BackfillRow]:
        stored_recipes = list(
            database.scalars(
                select(Recipe)
                .where(
                    Recipe.source_video_id == source_id,
                    Recipe.deleted_at.is_(None),
                )
                .order_by(Recipe.created_at, Recipe.id)
            )
        )
        if not stored_recipes:
            return []
        source = database.get(SourceVideo, source_id)
        if source is None:
            return [
                _row(stored, "skipped: source is gone") for stored in stored_recipes
            ]

        try:
            template = self._extract(source)
        except (AcquisitionError, ExtractionUnavailable) as error:
            # Named, not counted: a private video and a dead provider are the
            # difference between investigating the recipe and re-running the
            # command.
            reason = f"skipped: {type(error).__name__}"
            return [_row(stored, reason) for stored in stored_recipes]

        return [
            self._apply(database, stored, template, dry_run=dry_run)
            for stored in stored_recipes
        ]

    def _extract(self, source: SourceVideo) -> RecipeTemplate:
        # A fresh identifier per source. Nothing is billed against it: the
        # command builds its providers with the null usage sink, because a
        # provider attempt is recorded against an import job by foreign key
        # and this run has no job.
        job_id = uuid4()
        descriptor = SourceVideoDescriptor.from_stored(source)
        context = self._acquirer.acquire(descriptor, job_id=job_id)
        return self._extractor.extract(context, job_id=job_id)

    def _apply(
        self,
        database: Session,
        stored: Recipe,
        template: RecipeTemplate,
        *,
        dry_run: bool,
    ) -> BackfillRow:
        recipe = self._repository.to_dto(database, stored)
        tags = {
            "diets": list(template.diets),
            "cuisines": list(template.cuisines),
            "keywords": list(template.keywords),
            "keyword_proposals": list(template.keyword_proposals),
        }
        row = _row(stored, "", template=template)
        if not any(tags.values()):
            return replace(row, action="skipped: the model returned no tags")
        if dry_run:
            return replace(row, action="would tag")
        try:
            self._recipes.upsert(
                database,
                user_id=stored.user_id,
                # Everything but the tags is the cook's copy, carried through
                # untouched — including a title or a quantity they edited.
                recipe=recipe.model_copy(update=tags),
                base_revision=stored.revision,
            )
        except SyncConflict:
            return replace(row, action="skipped: edited during the run")
        return replace(row, action="tagged")

    def _untagged_manual_recipes(self, database: Session) -> list[BackfillRow]:
        """Recipes with no source at all, reported rather than silently absent."""

        stored_recipes = database.scalars(
            select(Recipe)
            .where(Recipe.deleted_at.is_(None), Recipe.source_video_id.is_(None))
            .order_by(Recipe.created_at, Recipe.id)
        )
        return [_row(stored, "skipped: no source video") for stored in stored_recipes]


def _row(
    stored: Recipe,
    action: str,
    *,
    template: RecipeTemplate | None = None,
) -> BackfillRow:
    return BackfillRow(
        recipe_id=stored.id,
        title=stored.title,
        creator_name=stored.creator_name,
        diets=tuple(value.value for value in (template.diets if template else ())),
        cuisines=tuple(
            value.value for value in (template.cuisines if template else ())
        ),
        keywords=tuple(
            value.value for value in (template.keywords if template else ())
        ),
        proposals=tuple(template.keyword_proposals if template else ()),
        action=action,
    )


_COLUMNS = ("recipe", "creator", "diets", "cuisines", "keywords", "proposed", "action")


def render_table(rows: Sequence[BackfillRow]) -> str:
    if not rows:
        return "No recipes to tag."
    body = [
        (
            row.title[:32],
            (row.creator_name or "—")[:18],
            ", ".join(row.diets) or "—",
            ", ".join(row.cuisines) or "—",
            ", ".join(row.keywords) or "—",
            ", ".join(row.proposals) or "—",
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


def build_service(settings: Settings) -> TagBackfillService:
    """The providers the import worker would use, with nothing billed."""

    acquirer: VideoAcquirer
    extractor: RecipeExtractor
    if settings.worker_provider_mode == "fake":
        acquirer = FakeRuntimeAcquirer()
        extractor = FakeRuntimeExtractor()
    elif settings.worker_provider_mode == "disabled":
        raise RuntimeError(
            "worker providers are disabled; configure live providers or set "
            "LADLE_WORKER_PROVIDER_MODE=fake for the local stack"
        )
    else:
        usage = NullProviderUsageSink()
        acquirer = runtime_acquirer(settings, usage=usage, metrics=runtime_metrics())
        extractor = runtime_extractor(settings, usage=usage)

    storage = runtime_object_storage()
    object_url: Callable[[str], str] | None = None
    if storage is not None:
        signing = storage

        def object_url(key: str) -> str:
            return signing.signed_read_url(key, expires_in=timedelta(hours=6))

    repository = RecipeRepository(object_url=object_url)
    return TagBackfillService(
        acquirer=acquirer,
        extractor=extractor,
        recipes=RecipeService(clock=SystemClock(), repository=repository),
        repository=repository,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Re-extract stored recipes to give them diet, cuisine and "
        "keyword tags",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="acquire, extract and print the table without writing anything",
    )
    parser.add_argument(
        "--limit",
        type=int,
        default=None,
        help="stop after this many source videos",
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
    written = sum(1 for row in rows if row.action == "tagged")
    proposed = sorted({value for row in rows for value in row.proposals})
    print(
        f"\n{len(rows)} recipes considered, "
        f"{written} written{' (dry run)' if dry_run else ''}."
    )
    if proposed:
        print(
            "Proposed keywords, held out of the filter until promoted: "
            + ", ".join(proposed)
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
