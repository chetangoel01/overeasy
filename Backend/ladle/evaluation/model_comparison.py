"""Pure compatibility checks and ranking for extraction benchmark artifacts."""

from collections import defaultdict
from collections.abc import Mapping, Sequence
from decimal import Decimal
from statistics import mean
from typing import Any

from pydantic import Field

from ladle.contracts.common import WireModel


class GateSummary(WireModel):
    passed: int
    total: int
    pass_rate: Decimal
    meets_gate: bool


class SparseSummary(WireModel):
    passed: int
    total: int
    meets_gate: bool
    cases: list[dict[str, Any]] = Field(default_factory=list)


class StructureSummary(WireModel):
    cook_time_matched: int
    cook_time_total: int
    cook_time_accuracy: Decimal
    ingredient_pairs_matched: int
    ingredient_pairs_total: int
    ingredient_pair_recall: Decimal
    ordered_step_phrases_matched: int
    ordered_step_phrases_total: int
    ordered_step_phrase_recall: Decimal


class LatencySummary(WireModel):
    median_ms: Decimal
    p95_ms: Decimal


class UsageSummary(WireModel):
    extraction_input_tokens: int
    extraction_output_tokens: int
    verification_calls: int
    verification_input_tokens: int
    verification_output_tokens: int
    total_input_tokens: int
    total_output_tokens: int
    reported_cost_usd: Decimal = Field(alias="reportedCostUSD")
    reported_cost_complete: bool
    cost_per_successful_case_usd: Decimal | None = Field(
        alias="costPerSuccessfulCaseUSD"
    )


class BenchmarkSummary(WireModel):
    valid_structured_outputs: GateSummary
    structure: StructureSummary
    latency: LatencySummary
    usage: UsageSummary


class RunArtifact(WireModel):
    corpus_name: str
    fixture_version: str
    partition: str
    reference_status: str
    corpus_digest: str
    prompt_version: str
    model_version: str
    label: str
    run_started_at: str
    visual_provider_calls: int
    cases: list[dict[str, Any]]
    whole_recipe_nutrition: GateSummary
    sparse_safety: SparseSummary
    benchmark: BenchmarkSummary


class ComparisonIdentity(WireModel):
    corpus_name: str
    fixture_version: str
    partition: str
    reference_status: str
    corpus_digest: str
    prompt_version: str
    case_count: int


class MetricRange(WireModel):
    minimum: Decimal
    maximum: Decimal


class ModelSummary(WireModel):
    model_id: str
    run_count: int
    eligible: bool
    gate_failures: list[str]
    valid_output_rate: Decimal
    nutrition_pass_rate: Decimal
    ingredient_pair_recall: Decimal
    ordered_step_phrase_recall: Decimal
    cook_time_accuracy: Decimal
    reported_cost_usd_per_run: Decimal | None = Field(
        alias="reportedCostUSDPerRun"
    )
    reported_cost_complete: bool
    median_latency_ms: Decimal
    p95_latency_ms: Decimal
    valid_output_rate_range: MetricRange
    nutrition_pass_rate_range: MetricRange
    ingredient_pair_recall_range: MetricRange
    ordered_step_phrase_recall_range: MetricRange
    cook_time_accuracy_range: MetricRange


class ComparisonReport(WireModel):
    identity: ComparisonIdentity
    models: list[ModelSummary]
    quality_leader_model_id: str | None
    comparable_quality_model_ids: list[str]
    value_winner_model_id: str | None


_COMPATIBILITY_FIELDS = {
    "corpusName": "corpus_name",
    "fixtureVersion": "fixture_version",
    "partition": "partition",
    "referenceStatus": "reference_status",
    "corpusDigest": "corpus_digest",
    "promptVersion": "prompt_version",
}
_EQUIVALENCE = Decimal("0.01")


def _rate(passed: int, total: int) -> Decimal:
    return Decimal(passed) / Decimal(total) if total else Decimal(0)


def _range(values: Sequence[Decimal]) -> MetricRange:
    return MetricRange(minimum=min(values), maximum=max(values))


def _gate_failures(runs: Sequence[RunArtifact]) -> list[str]:
    failures: list[str] = []
    if not all(
        run.benchmark.valid_structured_outputs.meets_gate
        and _rate(
            run.benchmark.valid_structured_outputs.passed,
            run.benchmark.valid_structured_outputs.total,
        )
        >= Decimal("0.95")
        for run in runs
    ):
        failures.append("validStructuredOutputs")
    if not all(
        run.whole_recipe_nutrition.meets_gate
        and _rate(
            run.whole_recipe_nutrition.passed,
            run.whole_recipe_nutrition.total,
        )
        >= Decimal("0.95")
        for run in runs
    ):
        failures.append("wholeRecipeNutrition")
    if not all(
        run.sparse_safety.meets_gate
        and run.sparse_safety.passed == 20
        and run.sparse_safety.total == 20
        for run in runs
    ):
        failures.append("sparseSafety")
    if not all(run.visual_provider_calls == 0 for run in runs):
        failures.append("visualProviderCalls")
    return failures


def _summarize(model_id: str, runs: Sequence[RunArtifact]) -> ModelSummary:
    valid_passed = sum(run.benchmark.valid_structured_outputs.passed for run in runs)
    valid_total = sum(run.benchmark.valid_structured_outputs.total for run in runs)
    nutrition_passed = sum(run.whole_recipe_nutrition.passed for run in runs)
    nutrition_total = sum(run.whole_recipe_nutrition.total for run in runs)
    structure = [run.benchmark.structure for run in runs]
    ingredients_matched = sum(value.ingredient_pairs_matched for value in structure)
    ingredients_total = sum(value.ingredient_pairs_total for value in structure)
    steps_matched = sum(value.ordered_step_phrases_matched for value in structure)
    steps_total = sum(value.ordered_step_phrases_total for value in structure)
    cook_matched = sum(value.cook_time_matched for value in structure)
    cook_total = sum(value.cook_time_total for value in structure)
    cost_complete = all(run.benchmark.usage.reported_cost_complete for run in runs)
    failures = _gate_failures(runs)
    return ModelSummary(
        model_id=model_id,
        run_count=len(runs),
        eligible=not failures,
        gate_failures=failures,
        valid_output_rate=_rate(valid_passed, valid_total),
        nutrition_pass_rate=_rate(nutrition_passed, nutrition_total),
        ingredient_pair_recall=_rate(ingredients_matched, ingredients_total),
        ordered_step_phrase_recall=_rate(steps_matched, steps_total),
        cook_time_accuracy=_rate(cook_matched, cook_total),
        reported_cost_usd_per_run=(
            sum(
                (run.benchmark.usage.reported_cost_usd for run in runs),
                Decimal(0),
            )
            / len(runs)
            if cost_complete
            else None
        ),
        reported_cost_complete=cost_complete,
        median_latency_ms=Decimal(
            str(mean(run.benchmark.latency.median_ms for run in runs))
        ),
        p95_latency_ms=Decimal(
            str(mean(run.benchmark.latency.p95_ms for run in runs))
        ),
        valid_output_rate_range=_range(
            [run.benchmark.valid_structured_outputs.pass_rate for run in runs]
        ),
        nutrition_pass_rate_range=_range(
            [run.whole_recipe_nutrition.pass_rate for run in runs]
        ),
        ingredient_pair_recall_range=_range(
            [value.ingredient_pair_recall for value in structure]
        ),
        ordered_step_phrase_recall_range=_range(
            [value.ordered_step_phrase_recall for value in structure]
        ),
        cook_time_accuracy_range=_range(
            [value.cook_time_accuracy for value in structure]
        ),
    )


def _quality_key(model: ModelSummary) -> tuple[Decimal, ...]:
    return (
        model.valid_output_rate,
        model.nutrition_pass_rate,
        model.ingredient_pair_recall,
        model.ordered_step_phrase_recall,
        model.cook_time_accuracy,
    )


def _comparable(candidate: ModelSummary, leader: ModelSummary) -> bool:
    return (
        candidate.valid_output_rate == leader.valid_output_rate
        and abs(candidate.nutrition_pass_rate - leader.nutrition_pass_rate)
        <= _EQUIVALENCE
        and abs(candidate.ingredient_pair_recall - leader.ingredient_pair_recall)
        <= _EQUIVALENCE
        and abs(
            candidate.ordered_step_phrase_recall
            - leader.ordered_step_phrase_recall
        )
        <= _EQUIVALENCE
        and abs(candidate.cook_time_accuracy - leader.cook_time_accuracy)
        <= _EQUIVALENCE
    )


def compare_runs(runs: Sequence[Mapping[str, Any]]) -> ComparisonReport:
    if len(runs) < 2:
        raise ValueError("comparison requires at least two runs")
    parsed = [RunArtifact.model_validate(run) for run in runs]
    labels = [run.label for run in parsed]
    if len(set(labels)) != len(labels):
        raise ValueError("comparison contains a duplicate label")
    for run in parsed:
        if run.benchmark.valid_structured_outputs.total != len(run.cases):
            raise ValueError("invalid validStructuredOutputs.total")
        if run.whole_recipe_nutrition.total != len(run.cases):
            raise ValueError("invalid wholeRecipeNutrition.total")
    reference = parsed[0]
    for run in parsed[1:]:
        for display, field in _COMPATIBILITY_FIELDS.items():
            if getattr(run, field) != getattr(reference, field):
                raise ValueError(f"incompatible {display}")
        if len(run.cases) != len(reference.cases):
            raise ValueError("incompatible caseCount")

    grouped: dict[str, list[RunArtifact]] = defaultdict(list)
    for run in parsed:
        grouped[run.model_version].append(run)
    models = [_summarize(model, values) for model, values in grouped.items()]
    models.sort(key=lambda value: (_quality_key(value), value.model_id), reverse=True)
    eligible = [model for model in models if model.eligible]
    leader = eligible[0] if eligible else None
    comparable = (
        [model for model in eligible if _comparable(model, leader)]
        if leader is not None
        else []
    )
    priced = [
        model
        for model in comparable
        if model.reported_cost_complete
        and model.reported_cost_usd_per_run is not None
    ]
    value_winner = min(
        priced,
        key=lambda value: (
            value.reported_cost_usd_per_run,
            value.median_latency_ms,
            value.p95_latency_ms,
        ),
        default=None,
    )
    return ComparisonReport(
        identity=ComparisonIdentity(
            corpus_name=reference.corpus_name,
            fixture_version=reference.fixture_version,
            partition=reference.partition,
            reference_status=reference.reference_status,
            corpus_digest=reference.corpus_digest,
            prompt_version=reference.prompt_version,
            case_count=len(reference.cases),
        ),
        models=models,
        quality_leader_model_id=leader.model_id if leader else None,
        comparable_quality_model_ids=[model.model_id for model in comparable],
        value_winner_model_id=value_winner.model_id if value_winner else None,
    )
