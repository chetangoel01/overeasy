"""Measure extraction quality against real videos, so prompt work is evidence-led.

Two stages, because acquisition is slow and billed while prompt iteration is
neither:

    acquire  fetch each video once and cache the AcquiredVideoContext as JSON
    extract  replay cached contexts through the current prompt and score them

Run `acquire` when the source set changes; run `extract` after every prompt or
extraction-layer edit and compare the scoreboard to the previous run.

    python scripts/eval_extraction.py acquire
    python scripts/eval_extraction.py extract --corpus tuning --label v3-baseline

Scored runs require an explicit tuning or held-out reference corpus. Nutrition
is a whole-case gate: servings, calories, and all three primary macros must be
within their documented tolerances, and the nutrition must have an auditable
basis. Structural measurements remain visible but do not inflate that gate.
"""

import argparse
import json
import re
import statistics
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from sqlalchemy import text

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
)
from ladle.evaluation.extraction import (
    EvaluationCorpus,
    IngredientNameQuantity,
    NutritionBasis,
    NutritionPrediction,
    StructuralPrediction,
    measure_structure,
    score_nutrition_case,
    summarize_nutrition_cases,
)
from ladle.extraction.claude import ClaudeRecipeExtractor
from ladle.extraction.models import RecipeExtraction
from ladle.extraction.prompt import (
    PROMPT_VERSION,
    SYSTEM_PROMPT,
    build_user_prompt,
)
from ladle.extraction.review import build_reviewed_template
from ladle.imports.source_identity import SourceIdentityParser
from ladle.worker.runtime import runtime_orchestrator, runtime_sessions

CACHE = Path(__file__).resolve().parent.parent / ".eval-cache"
RESULTS = CACHE / "results"
REFERENCE_FIXTURES = {
    "tuning": Path(__file__).resolve().parent.parent
    / "tests/fixtures/evaluation/text-only-tuning.json",
    "held-out": Path(__file__).resolve().parent.parent
    / "tests/fixtures/evaluation/text-only-held-out.json",
}

SOURCES = [
    "https://www.tiktok.com/@mishkamakesfood/video/7628226554589482271",
    "https://www.tiktok.com/@shicocooks/video/7619000339425119510",
    "https://www.tiktok.com/@mishkamakesfood/video/7655788084671401247",
    "https://www.instagram.com/reel/Ct-OnLxJlxw/",
    "https://www.instagram.com/reel/C6IsG9BI3WZ/",
    "https://www.instagram.com/reel/Cx8pqZDv7G0/",
    # Held back from the tuning above, to check the work on recipes it was
    # never shaped against: one caption-rich and full of fractions, one whose
    # real recipe lives on the creator's own site.
    "https://www.tiktok.com/@thegoldenbalance/video/7666186049663634702",
    "https://www.tiktok.com/@justine_snacks/video/7665677576647609630",
]


def slug(url: str) -> str:
    return url.rstrip("/").rsplit("/", 1)[-1][:32]


def _seed_job(
    descriptor: SourceVideoDescriptor, url: str
) -> tuple[uuid.UUID, SourceVideoDescriptor]:
    """Register a real job so provider spend lands in the usage ledger.

    These are billed calls against the same daily budget as production. Faking
    the job id would satisfy the foreign key nowhere and hide the cost, so the
    harness books its own work honestly.
    """

    sessions = runtime_sessions()
    job_id = uuid.uuid4()
    with sessions() as database, database.begin():
        user_id = database.execute(
            text("SELECT id FROM users ORDER BY created_at LIMIT 1")
        ).scalar_one()
        # Platform identity is unique, so an earlier run or a real import may
        # already own this row; reuse it rather than colliding.
        existing = database.execute(
            text(
                "SELECT id FROM source_videos"
                " WHERE platform = :platform AND platform_video_id = :vid"
            ),
            {"platform": descriptor.platform, "vid": descriptor.platform_video_id},
        ).scalar_one_or_none()
        if existing is None:
            database.execute(
                text(
                    "INSERT INTO source_videos (id, platform, platform_video_id,"
                    " canonical_url, source_revision, metadata_json)"
                    " VALUES (:id, :platform, :vid, :url, :rev, '{}'::json)"
                ),
                {
                    "id": descriptor.source_video_id,
                    "platform": descriptor.platform,
                    "vid": descriptor.platform_video_id,
                    "url": descriptor.canonical_url,
                    "rev": descriptor.source_revision,
                },
            )
        else:
            descriptor = descriptor.model_copy(update={"source_video_id": existing})
        database.execute(
            text(
                "INSERT INTO import_jobs (id, user_id, source_video_id, source_url,"
                " canonical_url, source, status, stage, retry_count, bypass_cache,"
                " idempotency_key, created_at, updated_at)"
                " VALUES (:id, :user, :source, :url, :canonical, :platform,"
                " 'parsing', 'parsing', 0, false, :key, now(), now())"
            ),
            {
                "id": job_id,
                "user": user_id,
                "source": descriptor.source_video_id,
                "url": url,
                "canonical": descriptor.canonical_url,
                "platform": descriptor.platform,
                "key": f"eval-{job_id}",
            },
        )
    return job_id, descriptor


def _retire_job(job_id: uuid.UUID) -> None:
    """Leave no job parked in parsing for the sweeper to reclaim later."""

    with runtime_sessions()() as database, database.begin():
        database.execute(
            text(
                "UPDATE import_jobs SET status='failed', stage='failed',"
                " diagnostic_code='evalHarness', completed_at=now(),"
                " updated_at=now() WHERE id=:id"
            ),
            {"id": job_id},
        )


def acquire() -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    resolver = SourceIdentityParser()
    acquirer = runtime_orchestrator()._acquirer
    for url in SOURCES:
        target = CACHE / f"{slug(url)}.json"
        if target.exists():
            print(f"cached   {slug(url)}")
            continue
        identity = resolver.parse(url)
        descriptor = SourceVideoDescriptor(
            source_video_id=uuid.uuid4(),
            platform=identity.platform.value,
            platform_video_id=identity.platform_video_id,
            canonical_url=identity.canonical_url,
            source_revision="eval-1",
        )
        job_id, descriptor = _seed_job(descriptor, url)
        try:
            context = acquirer.acquire(descriptor, job_id=job_id)
        except Exception as error:
            print(f"FAILED   {slug(url)}: {type(error).__name__}: {error}")
            continue
        finally:
            _retire_job(job_id)
        target.write_text(context.model_dump_json(indent=2))
        spoken = [value for value in context.transcript if value.generated]
        print(
            f"acquired {slug(url)}  transcript={len(context.transcript)} "
            f"(generated={len(spoken)}) links={len(context.linked_documents)} "
            f"diagnostics={context.diagnostics}"
        )


@dataclass
class Score:
    name: str
    transcript_segments: int
    transcript_provenance: str
    timed_fraction: float
    ingredients: int
    with_quantity: float
    with_metric: float
    steps: int
    steps_timed: float
    # Timers drive cooking mode's registry and its notifications, so a missed
    # "simmer for ten minutes" costs the cook a feature, not just a detail.
    timers: int
    timed_phrases: int
    servings: str
    servings_basis: str
    method_provenance: str
    review_status: str
    top_uncertainties: list[str]
    notes: int
    title: str

    def row(self) -> str:
        return (
            f"{self.name:<24} {self.transcript_segments:>4} "
            f"{self.ingredients:>5} "
            f"{self.with_quantity:>7.0%} {self.with_metric:>7.0%} "
            f"{self.steps:>5} "
            f"{self.timers:>3}/{self.timed_phrases:<3} {self.notes:>5} "
            f"{self.servings:>6} {self.servings_basis:<18} "
            f"{self.method_provenance:<9} {self.review_status}"
        )


def _fraction(values: list[bool]) -> float:
    return (sum(values) / len(values)) if values else 0.0


#: Duration phrases in the evidence. A rough recall target for timers: if the
#: creator said "simmer for ten minutes" and no timer came back, cooking mode
#: silently lost a countdown it could have offered.
_DURATION = re.compile(
    r"\b(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten|fifteen|twenty|"
    r"thirty|forty|forty-five|sixty|half|a couple of|a few)\s*"
    r"(?:-\s*\d+\s*)?(?:to\s+\d+\s*)?"
    r"(?:seconds?|secs?|minutes?|mins?|hours?|hrs?)\b",
    re.IGNORECASE,
)


def _duration_phrases(context: AcquiredVideoContext) -> int:
    haystack = " ".join(
        [
            context.title or "",
            context.description,
            *(value.text for value in context.transcript),
            *(value.text for value in context.linked_documents),
        ]
    )
    return len(set(match.group(0).lower() for match in _DURATION.finditer(haystack)))


def _load_corpus(partition: str) -> EvaluationCorpus:
    return EvaluationCorpus.model_validate_json(
        REFERENCE_FIXTURES[partition].read_text()
    )


def _nutrition_prediction(
    extraction: RecipeExtraction,
) -> NutritionPrediction | None:
    nutrition = extraction.nutrition
    if (
        extraction.servings is None
        or nutrition is None
        or nutrition.calories is None
        or nutrition.protein_grams is None
        or nutrition.carbohydrate_grams is None
        or nutrition.fat_grams is None
    ):
        return None
    raw_basis = getattr(nutrition, "basis", "unknown")
    basis = cast(
        NutritionBasis,
        raw_basis if raw_basis in {"creatorStated", "usdaCalculated"} else "unknown",
    )
    return NutritionPrediction(
        servings=extraction.servings,
        calories=nutrition.calories,
        protein_grams=nutrition.protein_grams,
        carbohydrate_grams=nutrition.carbohydrate_grams,
        fat_grams=nutrition.fat_grams,
        basis=basis,
    )


def _structural_prediction(extraction: RecipeExtraction) -> StructuralPrediction:
    return StructuralPrediction(
        stated_cook_time_minutes=extraction.cooking_minutes,
        ingredient_name_quantities=[
            IngredientNameQuantity(name=value.name, quantity=value.quantity_text)
            for value in extraction.ingredients
            if value.quantity_text is not None
        ],
        steps=[value.instruction for value in extraction.steps],
    )


def extract(label: str, only: str | None, partition: str) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    # Go through the structured client rather than ClaudeRecipeExtractor.extract,
    # which returns the reviewed template. The raw RecipeExtraction is what
    # carries servingsBasis, methodProvenance and the metric amounts — exactly
    # the fields worth watching while tuning the prompt.
    extractor = cast(ClaudeRecipeExtractor, runtime_orchestrator()._extractor)
    client = extractor._client
    scores: list[Score] = []
    corpus = _load_corpus(partition)
    references = [
        case
        for case in corpus.cases
        if only is None or only in case.id or only in case.cache_key
    ]
    if not references:
        raise ValueError(f"no {partition} reference case matches --only={only!r}")
    dump: dict[str, Any] = {
        "corpusName": corpus.corpus_name,
        "fixtureVersion": corpus.fixture_version,
        "partition": corpus.partition,
        "referenceStatus": corpus.reference_status,
        "promptVersion": PROMPT_VERSION,
        "modelVersion": extractor.model_id,
        "label": label,
        "cases": [],
    }
    nutrition_scores = []

    for reference in references:
        path = CACHE / f"{reference.cache_key}.json"
        if not path.exists():
            nutrition_score = score_nutrition_case(reference.nutrition, None)
            nutrition_scores.append(nutrition_score)
            dump["cases"].append(
                {
                    "id": reference.id,
                    "sourceURL": reference.source_url,
                    "nutrition": nutrition_score.model_dump(
                        mode="json", by_alias=True
                    ),
                    "structure": None,
                    "error": f"missing acquired context: {path.name}",
                }
            )
            continue
        context = AcquiredVideoContext.model_validate_json(path.read_text())
        try:
            response = client.parse_recipe(
                model=extractor.model_id,
                max_tokens=extractor._max_tokens,
                system=SYSTEM_PROMPT,
                user_prompt=build_user_prompt(context),
            )
            extraction = response.parsed_output
            if extraction is None:
                print(
                    f"FAILED   {path.stem}: no parsed output ({response.stop_reason})"
                )
                nutrition_score = score_nutrition_case(reference.nutrition, None)
                nutrition_scores.append(nutrition_score)
                dump["cases"].append(
                    {
                        "id": reference.id,
                        "sourceURL": reference.source_url,
                        "nutrition": nutrition_score.model_dump(
                            mode="json", by_alias=True
                        ),
                        "structure": None,
                        "error": f"no parsed output: {response.stop_reason}",
                    }
                )
                continue
        except Exception as error:
            print(f"FAILED   {path.stem}: {type(error).__name__}: {error}")
            nutrition_score = score_nutrition_case(reference.nutrition, None)
            nutrition_scores.append(nutrition_score)
            dump["cases"].append(
                {
                    "id": reference.id,
                    "sourceURL": reference.source_url,
                    "nutrition": nutrition_score.model_dump(
                        mode="json", by_alias=True
                    ),
                    "structure": None,
                    "error": f"{type(error).__name__}: {error}",
                }
            )
            continue
        template = build_reviewed_template(extraction, context=context)
        nutrition_score = score_nutrition_case(
            reference.nutrition,
            _nutrition_prediction(extraction),
        )
        nutrition_scores.append(nutrition_score)
        structure = measure_structure(
            reference.structure,
            _structural_prediction(extraction),
        )

        quantified = [
            value for value in extraction.ingredients if not value.is_to_taste
        ]
        provenances = {value.provenance for value in context.transcript}
        score = Score(
            name=path.stem,
            transcript_segments=len(context.transcript),
            transcript_provenance=",".join(sorted(provenances)) or "none",
            timed_fraction=_fraction(
                [value.start_seconds is not None for value in context.transcript]
            ),
            ingredients=len(extraction.ingredients),
            with_quantity=_fraction(
                [value.quantity_text is not None for value in quantified]
            ),
            with_metric=_fraction(
                [value.metric_amount is not None for value in quantified]
            ),
            steps=len(extraction.steps),
            steps_timed=_fraction(
                [value.source_start_seconds is not None for value in extraction.steps]
            ),
            timers=sum(len(value.timers) for value in extraction.steps),
            timed_phrases=_duration_phrases(context),
            servings=str(extraction.servings) if extraction.servings else "-",
            servings_basis=extraction.servings_basis,
            method_provenance=extraction.method_provenance,
            review_status=template.review_status.value,
            top_uncertainties=[value.reason for value in template.uncertainties],
            notes=len(extraction.notes),
            title=extraction.title,
        )
        scores.append(score)
        dump["cases"].append(
            {
                "id": reference.id,
                "sourceURL": reference.source_url,
                "nutrition": nutrition_score.model_dump(
                    mode="json", by_alias=True
                ),
                "structure": structure.model_dump(mode="json", by_alias=True),
                "title": extraction.title,
                "promptCharacters": len(build_user_prompt(context)),
                "transcriptProvenance": score.transcript_provenance,
                "ingredients": [
                    {
                        "quantityText": value.quantity_text,
                        "name": value.name,
                        "metricAmount": (
                            str(value.metric_amount)
                            if value.metric_amount is not None
                            else None
                        ),
                        "metricUnit": value.metric_unit,
                        "isToTaste": value.is_to_taste,
                    }
                    for value in extraction.ingredients
                ],
                "steps": [
                    {
                        "instruction": value.instruction,
                        "start": value.source_start_seconds,
                        "end": value.source_end_seconds,
                        "timers": [
                            f"{timer.label}={timer.duration_seconds}s"
                            for timer in value.timers
                        ],
                    }
                    for value in extraction.steps
                ],
                "notes": extraction.notes,
                "uncertainties": score.top_uncertainties,
            }
        )

    header = (
        f"{'source':<24} {'segs':>4} {'ingr':>5} "
        f"{'qty':>7} {'metric':>7} {'steps':>5} "
        f"{'tmr/said':<7} {'notes':>5} "
        f"{'serv':>6} {'basis':<18} {'method':<9} review"
    )
    print(f"\n=== {label}  prompt={PROMPT_VERSION} ===")
    print(header)
    print("-" * len(header))
    for score in scores:
        print(score.row())

    if scores:
        print("-" * len(header))
        found = sum(s.timers for s in scores)
        said = sum(s.timed_phrases for s in scores)
        print(
            f"{'MEAN':<24} {'':>4} {'':>5} "
            f"{statistics.mean(s.with_quantity for s in scores):>7.0%} "
            f"{statistics.mean(s.with_metric for s in scores):>7.0%} {'':>5} "
            f"{found:>3}/{said:<3}"
        )
        ready = sum(s.review_status == "ready" for s in scores)
        print(f"\nready {ready}/{len(scores)}   transcript sources:")
        for score in scores:
            print(f"  {score.name:<24} {score.transcript_provenance}")
        print("\nuncertainties driving review:")
        for score in scores:
            for reason in score.top_uncertainties:
                print(f"  {score.name:<24} {reason[:96]}")

    nutrition_summary = summarize_nutrition_cases(nutrition_scores)
    dump["wholeRecipeNutrition"] = nutrition_summary.model_dump(
        mode="json", by_alias=True
    )
    print(
        "\nwhole-recipe nutrition "
        f"{nutrition_summary.passed}/{nutrition_summary.total} "
        f"({nutrition_summary.pass_rate:.1%}) "
        f"gate={'PASS' if nutrition_summary.meets_gate else 'FAIL'}"
    )
    if corpus.reference_status != "verified":
        print("reference status is scaffold; this run is not accuracy evidence")

    out = RESULTS / f"{label}.json"
    out.write_text(json.dumps(dump, indent=2, ensure_ascii=False))
    print(f"\nwrote {out}")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("acquire")
    run = sub.add_parser("extract")
    run.add_argument("--label", default="run")
    run.add_argument("--only", default=None)
    run.add_argument("--corpus", choices=REFERENCE_FIXTURES, required=True)
    arguments = parser.parse_args()

    if arguments.command == "acquire":
        acquire()
    else:
        extract(arguments.label, arguments.only, arguments.corpus)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
