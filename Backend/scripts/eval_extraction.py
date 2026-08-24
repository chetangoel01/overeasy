"""Replay the production text pipeline against the locked evaluation corpus.

    python scripts/eval_extraction.py extract --corpus tuning --label v1-tuning

Scored runs require an explicit tuning or held-out reference corpus. Nutrition
is a whole-case gate: servings, calories, and all three primary macros must be
within their documented tolerances, and the nutrition must have an auditable
basis. Structural measurements remain visible but do not inflate that gate.
"""

import argparse
import json
import math
import re
import statistics
import sys
import time
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import httpx
from anthropic import Anthropic

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.config import Settings
from ladle.evaluation.extraction import (
    EvaluationCorpus,
    EvaluationReferenceCase,
    IngredientNameQuantity,
    SparseSafetyCase,
    StructuralPrediction,
    measure_structure,
    score_nutrition_case,
    summarize_nutrition_cases,
    whole_recipe_prediction,
)
from ladle.extraction.claude import (
    AnthropicStructuredClient,
    ClaudeStructuredClient,
    ClaudeStructuredResponse,
)
from ladle.extraction.evidence_gate import (
    InsufficientTextEvidence,
    require_recipe_evidence,
)
from ladle.extraction.models import RecipeExtraction
from ladle.extraction.openrouter import OpenRouterStructuredClient
from ladle.extraction.prompt import (
    PROMPT_VERSION,
    SYSTEM_PROMPT,
    build_user_prompt,
)
from ladle.extraction.review import build_reviewed_template
from ladle.extraction.verification import (
    AnthropicVerificationClient,
    OpenRouterVerificationClient,
    StructuredVerificationResponse,
    TargetedRecipeVerifier,
    VerificationEvidence,
    VerificationIssue,
    VerificationModelClient,
    verification_evidence,
)
from ladle.nutrition.calculator import NutritionCalculator
from ladle.nutrition.creator import apply_creator_facts
from ladle.nutrition.usda import USDAClient
from ladle.recipes.template_clone import RecipeTemplate

CACHE = Path(__file__).resolve().parent.parent / ".eval-cache"
RESULTS = CACHE / "results"
REFERENCE_FIXTURES = {
    "tuning": Path(__file__).resolve().parent.parent
    / "tests/fixtures/evaluation/text-only-tuning.json",
    "held-out": Path(__file__).resolve().parent.parent
    / "tests/fixtures/evaluation/text-only-held-out.json",
}


@dataclass(frozen=True)
class EvaluationPipeline:
    client: ClaudeStructuredClient
    model_id: str
    max_tokens: int
    nutrition: NutritionCalculator
    verifier: TargetedRecipeVerifier | None
    verification_recorder: "RecordingVerificationClient | None"

    def run(
        self,
        context: AcquiredVideoContext,
    ) -> tuple[ClaudeStructuredResponse, RecipeExtraction, RecipeTemplate]:
        if self.verification_recorder is not None:
            self.verification_recorder.reset()
        response = self.client.parse_recipe(
            model=self.model_id,
            max_tokens=self.max_tokens,
            system=SYSTEM_PROMPT,
            user_prompt=build_user_prompt(context),
        )
        extraction = response.parsed_output
        if extraction is None:
            raise ValueError(f"no parsed output: {response.stop_reason}")
        template = build_reviewed_template(extraction, context=context)
        text_evidence = verification_evidence(context)
        template = apply_creator_facts(
            template,
            (value.text for value in text_evidence),
        )
        nutrition = self.nutrition.calculate(template)
        if nutrition is not None:
            template = template.model_copy(update={"nutrition": nutrition})
        if self.verifier is not None:
            template = self.verifier.verify(
                template,
                evidence=text_evidence,
                job_id=uuid.uuid4(),
            )
        return response, extraction, template


@dataclass(frozen=True)
class VerificationUsage:
    calls: int = 0
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: Decimal = Decimal(0)
    reported_cost_complete: bool = True


class RecordingVerificationClient:
    def __init__(self, client: VerificationModelClient) -> None:
        self._client = client
        self._usage = VerificationUsage()

    @property
    def usage(self) -> VerificationUsage:
        return self._usage

    def reset(self) -> None:
        self._usage = VerificationUsage()

    def propose_patches(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        issues: list[VerificationIssue],
        evidence: list[VerificationEvidence],
    ) -> StructuredVerificationResponse:
        try:
            response = self._client.propose_patches(
                model=model,
                max_tokens=max_tokens,
                template=template,
                issues=issues,
                evidence=evidence,
            )
        except Exception:
            self._usage = VerificationUsage(
                calls=self._usage.calls + 1,
                input_tokens=self._usage.input_tokens,
                output_tokens=self._usage.output_tokens,
                cost_usd=self._usage.cost_usd,
                reported_cost_complete=False,
            )
            raise
        self._usage = VerificationUsage(
            calls=self._usage.calls + 1,
            input_tokens=self._usage.input_tokens + response.input_tokens,
            output_tokens=self._usage.output_tokens + response.output_tokens,
            cost_usd=self._usage.cost_usd + (response.cost_usd or Decimal(0)),
            reported_cost_complete=(
                self._usage.reported_cost_complete and response.cost_usd is not None
            ),
        )
        return response


def _pipeline(
    settings: Settings,
    *,
    model_id: str | None = None,
) -> EvaluationPipeline:
    if settings.usda_api_key is None:
        raise RuntimeError(
            "evaluation requires LADLE_USDA_API_KEY for calculated-nutrition cases"
        )
    verifier: TargetedRecipeVerifier | None = None
    verification_recorder: RecordingVerificationClient | None = None
    if settings.extraction_provider == "openrouter":
        if settings.openrouter_api_key is None:
            raise RuntimeError("evaluation requires LADLE_OPENROUTER_API_KEY")
        key = settings.openrouter_api_key.get_secret_value()
        client: ClaudeStructuredClient = OpenRouterStructuredClient(
            http=httpx.Client(
                timeout=settings.openrouter_timeout_seconds,
                trust_env=False,
            ),
            api_key=key,
            base_url=str(settings.openrouter_base_url),
        )
        model_id = model_id or settings.openrouter_model_id
        max_tokens = settings.openrouter_max_tokens
        if settings.recipe_verification_enabled:
            verification_recorder = RecordingVerificationClient(
                OpenRouterVerificationClient(
                    http=httpx.Client(
                        timeout=settings.openrouter_timeout_seconds,
                        trust_env=False,
                    ),
                    api_key=key,
                    base_url=str(settings.openrouter_base_url),
                )
            )
            verifier = TargetedRecipeVerifier(
                client=verification_recorder,
                model_id=model_id,
                max_tokens=settings.recipe_verification_max_tokens,
            )
    else:
        if settings.anthropic_api_key is None:
            raise RuntimeError("evaluation requires LADLE_ANTHROPIC_API_KEY")
        anthropic = Anthropic(
            api_key=settings.anthropic_api_key.get_secret_value(),
            base_url=str(settings.anthropic_base_url),
            timeout=settings.anthropic_timeout_seconds,
        )
        client = AnthropicStructuredClient(anthropic)
        model_id = model_id or settings.anthropic_model_id
        max_tokens = settings.anthropic_max_tokens
        if settings.recipe_verification_enabled:
            verification_recorder = RecordingVerificationClient(
                AnthropicVerificationClient(anthropic)
            )
            verifier = TargetedRecipeVerifier(
                client=verification_recorder,
                model_id=model_id,
                max_tokens=settings.recipe_verification_max_tokens,
                provider="anthropic",
            )
    return EvaluationPipeline(
        client=client,
        model_id=model_id,
        max_tokens=max_tokens,
        nutrition=NutritionCalculator(
            USDAClient(
                http=httpx.Client(
                    timeout=settings.usda_timeout_seconds,
                    trust_env=False,
                ),
                api_key=settings.usda_api_key.get_secret_value(),
                base_url=str(settings.usda_base_url),
                maximum_candidates=settings.usda_maximum_candidates,
            )
        ),
        verifier=verifier,
        verification_recorder=verification_recorder,
    )


def _context(
    case: EvaluationReferenceCase,
    *,
    fixture_version: str,
) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid.uuid5(uuid.NAMESPACE_URL, case.source_url),
            platform="youtube",
            platform_video_id=case.cache_key,
            canonical_url=case.source_url,
            source_revision=fixture_version,
        ),
        is_public=True,
        title=case.evidence.title,
        description=case.evidence.description,
        creator_name=case.attribution,
        language="en",
        linked_documents=[
            LinkedDocument(
                url=case.source_url,
                text=case.evidence.linked_document_text,
                provenance="public-government-recipe",
            )
        ],
        visual_observations=[],
        diagnostics=["lockedTextEvaluationFixture"],
    )


def _safety_context(case: SparseSafetyCase) -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid.uuid5(uuid.NAMESPACE_URL, case.source_url),
            platform="youtube",
            platform_video_id=case.id,
            canonical_url=case.source_url,
            source_revision="safety-v1",
        ),
        is_public=True,
        title=case.evidence.title,
        description=case.evidence.description,
        transcript=[
            TextEvidence(
                text=value,
                provenance="synthetic-transcript",
                generated=False,
            )
            for value in case.evidence.transcript
        ],
        linked_documents=[
            LinkedDocument(
                url=case.source_url,
                text=value,
                provenance="synthetic-linked-document",
            )
            for value in case.evidence.linked_document_texts
        ],
        visual_observations=[],
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


def _latency_summary(values: list[int]) -> dict[str, int | float]:
    ordered = sorted(values)
    return {
        "medianMs": statistics.median(ordered),
        "p95Ms": ordered[math.ceil(len(ordered) * 0.95) - 1],
    }


def _rate(numerator: int, denominator: int) -> float:
    return numerator / denominator if denominator else 0.0


def _benchmark_summary(cases: list[dict[str, Any]]) -> dict[str, Any]:
    structures = [case["structure"] for case in cases if case["structure"]]
    successful = len(structures)
    cook_times = [
        structure["cookTimeMatches"]
        for structure in structures
        if structure["cookTimeMatches"] is not None
    ]
    ingredient_matched = sum(
        structure["ingredientPairsMatched"] for structure in structures
    )
    ingredient_total = sum(
        structure["ingredientPairsTotal"] for structure in structures
    )
    steps_matched = sum(
        structure["orderedStepPhrasesMatched"] for structure in structures
    )
    steps_total = sum(
        structure["orderedStepPhrasesTotal"] for structure in structures
    )
    usages = [case["usage"] for case in cases]
    extraction_input = sum(value["extractionInputTokens"] for value in usages)
    extraction_output = sum(value["extractionOutputTokens"] for value in usages)
    verification_input = sum(value["verificationInputTokens"] for value in usages)
    verification_output = sum(value["verificationOutputTokens"] for value in usages)
    verification_calls = sum(value["verificationCalls"] for value in usages)
    cost_complete = all(value["reportedCostComplete"] for value in usages)
    reported_cost = sum(
        (
            Decimal(value["extractionCostUSD"] or 0)
            + Decimal(value["verificationCostUSD"] or 0)
        )
        for value in usages
    )
    return {
        "validStructuredOutputs": {
            "passed": successful,
            "total": len(cases),
            "passRate": _rate(successful, len(cases)),
            "meetsGate": _rate(successful, len(cases)) >= 0.95,
        },
        "structure": {
            "cookTimeMatched": sum(bool(value) for value in cook_times),
            "cookTimeTotal": len(cook_times),
            "cookTimeAccuracy": _rate(
                sum(bool(value) for value in cook_times), len(cook_times)
            ),
            "ingredientPairsMatched": ingredient_matched,
            "ingredientPairsTotal": ingredient_total,
            "ingredientPairRecall": _rate(ingredient_matched, ingredient_total),
            "orderedStepPhrasesMatched": steps_matched,
            "orderedStepPhrasesTotal": steps_total,
            "orderedStepPhraseRecall": _rate(steps_matched, steps_total),
        },
        "latency": _latency_summary([case["latencyMs"] for case in cases]),
        "usage": {
            "extractionInputTokens": extraction_input,
            "extractionOutputTokens": extraction_output,
            "verificationCalls": verification_calls,
            "verificationInputTokens": verification_input,
            "verificationOutputTokens": verification_output,
            "totalInputTokens": extraction_input + verification_input,
            "totalOutputTokens": extraction_output + verification_output,
            "reportedCostUSD": str(reported_cost),
            "reportedCostComplete": cost_complete,
            "costPerSuccessfulCaseUSD": (
                str(reported_cost / successful)
                if cost_complete and successful
                else None
            ),
        },
    }


def _case_usage(
    response: ClaudeStructuredResponse | None,
    verification: VerificationUsage,
) -> dict[str, object]:
    return {
        "extractionInputTokens": response.input_tokens if response else 0,
        "extractionOutputTokens": response.output_tokens if response else 0,
        "extractionCostUSD": (
            str(response.cost_usd)
            if response is not None and response.cost_usd is not None
            else None
        ),
        "verificationCalls": verification.calls,
        "verificationInputTokens": verification.input_tokens,
        "verificationOutputTokens": verification.output_tokens,
        "verificationCostUSD": str(verification.cost_usd),
        "reportedCostComplete": (
            response is not None
            and response.cost_usd is not None
            and verification.reported_cost_complete
        ),
    }


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


def _new_result_path(label: str) -> Path:
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", label) is None:
        raise ValueError("benchmark label contains unsafe characters")
    path = RESULTS / f"{label}.json"
    if path.exists():
        raise FileExistsError(f"benchmark artifact already exists: {path}")
    return path


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


def extract(
    label: str,
    only: str | None,
    partition: str,
    model: str | None = None,
) -> None:
    RESULTS.mkdir(parents=True, exist_ok=True)
    out = _new_result_path(label)
    scores: list[Score] = []
    corpus = _load_corpus(partition)
    pipeline = _pipeline(Settings(), model_id=model)
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
        "corpusDigest": corpus.corpus_digest,
        "promptVersion": PROMPT_VERSION,
        "modelVersion": pipeline.model_id,
        "label": label,
        "runStartedAt": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "visualProviderCalls": 0,
        "cases": [],
    }
    nutrition_scores = []

    for reference in references:
        context = _context(reference, fixture_version=corpus.fixture_version)
        started = time.perf_counter()
        try:
            response, extraction, template = pipeline.run(context)
        except Exception as error:
            latency_ms = round((time.perf_counter() - started) * 1_000)
            verification = (
                pipeline.verification_recorder.usage
                if pipeline.verification_recorder is not None
                else VerificationUsage()
            )
            print(
                f"FAILED   {reference.cache_key}: "
                f"{type(error).__name__}: {error}"
            )
            nutrition_score = score_nutrition_case(
                reference.nutrition,
                None,
                expected_basis=reference.expected_nutrition_basis,
            )
            nutrition_scores.append(nutrition_score)
            dump["cases"].append(
                {
                    "id": reference.id,
                    "sourceURL": reference.source_url,
                    "expectedNutritionBasis": (
                        reference.expected_nutrition_basis
                    ),
                    "nutrition": nutrition_score.model_dump(
                        mode="json", by_alias=True
                    ),
                    "structure": None,
                    "latencyMs": latency_ms,
                    "usage": _case_usage(None, verification),
                    "error": f"{type(error).__name__}: {error}",
                }
            )
            continue
        latency_ms = round((time.perf_counter() - started) * 1_000)
        verification = (
            pipeline.verification_recorder.usage
            if pipeline.verification_recorder is not None
            else VerificationUsage()
        )
        prediction = whole_recipe_prediction(template)
        nutrition_score = score_nutrition_case(
            reference.nutrition,
            prediction,
            expected_basis=reference.expected_nutrition_basis,
        )
        nutrition_scores.append(nutrition_score)
        structure = measure_structure(
            reference.structure,
            _structural_prediction(extraction),
        )

        quantified = [
            value for value in extraction.ingredients if not value.is_to_taste
        ]
        provenances = {
            *(value.provenance for value in context.transcript),
            *(value.provenance for value in context.linked_documents),
        }
        score = Score(
            name=reference.cache_key,
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
                "expectedNutritionBasis": reference.expected_nutrition_basis,
                "nutrition": nutrition_score.model_dump(
                    mode="json", by_alias=True
                ),
                "prediction": (
                    prediction.model_dump(mode="json", by_alias=True)
                    if prediction is not None
                    else None
                ),
                "structure": structure.model_dump(mode="json", by_alias=True),
                "title": extraction.title,
                "latencyMs": latency_ms,
                "promptCharacters": len(build_user_prompt(context)),
                "usage": _case_usage(response, verification),
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

    safety_references = [
        case
        for case in corpus.safety_cases
        if only is None or only in case.id
    ]
    safety_results: list[dict[str, object]] = []
    for safety_reference in safety_references:
        try:
            require_recipe_evidence(_safety_context(safety_reference))
            actual = "accepted"
        except InsufficientTextEvidence:
            actual = "insufficientTextEvidence"
        safety_results.append(
            {
                "id": safety_reference.id,
                "expected": safety_reference.expected_outcome,
                "actual": actual,
                "passes": actual == safety_reference.expected_outcome,
            }
        )
    safety_passed = sum(bool(value["passes"]) for value in safety_results)
    dump["sparseSafety"] = {
        "passed": safety_passed,
        "total": len(safety_results),
        "meetsGate": (
            bool(safety_results) and safety_passed == len(safety_results)
        ),
        "cases": safety_results,
    }

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
    dump["benchmark"] = _benchmark_summary(dump["cases"])
    print(
        "\nwhole-recipe nutrition "
        f"{nutrition_summary.passed}/{nutrition_summary.total} "
        f"({nutrition_summary.pass_rate:.1%}) "
        f"gate={'PASS' if nutrition_summary.meets_gate else 'FAIL'}"
    )
    if safety_results:
        print(
            "sparse safety "
            f"{safety_passed}/{len(safety_results)} "
            f"gate={'PASS' if safety_passed == len(safety_results) else 'FAIL'}"
        )
    print("visual provider calls 0 gate=PASS")
    if corpus.reference_status != "verified":
        print("reference status is scaffold; this run is not accuracy evidence")

    out.write_text(json.dumps(dump, indent=2, ensure_ascii=False) + "\n")
    print(f"\nwrote {out}")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("extract")
    run.add_argument("--label", default="run")
    run.add_argument("--only", default=None)
    run.add_argument("--model", default=None)
    run.add_argument("--corpus", choices=REFERENCE_FIXTURES, required=True)
    arguments = parser.parse_args()

    extract(arguments.label, arguments.only, arguments.corpus, arguments.model)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
