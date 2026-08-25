import json
import sys
from decimal import Decimal
from pathlib import Path

from ladle.config import Settings
from ladle.extraction.claude import ClaudeStructuredResponse
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedStep,
    RecipeExtraction,
)
from ladle.extraction.verification import (
    StructuredVerificationResponse,
    VerificationResponse,
    VerificationUnavailable,
)
from scripts import eval_extraction


def test_latency_summary_uses_median_and_nearest_rank_p95() -> None:
    assert eval_extraction._latency_summary([100, 200, 300, 400]) == {
        "medianMs": 250,
        "p95Ms": 400,
    }


def test_benchmark_summary_aggregates_quality_latency_and_full_usage() -> None:
    cases = [
        {
            "latencyMs": 100,
            "structure": {
                "cookTimeMatches": True,
                "ingredientPairsMatched": 2,
                "ingredientPairsTotal": 3,
                "orderedStepPhrasesMatched": 3,
                "orderedStepPhrasesTotal": 4,
            },
            "usage": {
                "extractionInputTokens": 10,
                "extractionOutputTokens": 20,
                "extractionCostUSD": "0.10",
                "verificationCalls": 1,
                "verificationInputTokens": 5,
                "verificationOutputTokens": 2,
                "verificationCostUSD": "0.05",
                "normalizationCalls": 1,
                "normalizationInputTokens": 7,
                "normalizationOutputTokens": 3,
                "normalizationCostUSD": "0.02",
                "reportedCostComplete": True,
            },
        },
        {
            "latencyMs": 300,
            "structure": None,
            "error": "ExtractionUnavailable",
            "usage": {
                "extractionInputTokens": 0,
                "extractionOutputTokens": 0,
                "extractionCostUSD": None,
                "verificationCalls": 0,
                "verificationInputTokens": 0,
                "verificationOutputTokens": 0,
                "verificationCostUSD": "0",
                "normalizationCalls": 0,
                "normalizationInputTokens": 0,
                "normalizationOutputTokens": 0,
                "normalizationCostUSD": "0",
                "reportedCostComplete": False,
            },
        },
    ]

    assert eval_extraction._benchmark_summary(cases) == {
        "validStructuredOutputs": {
            "passed": 1,
            "total": 2,
            "passRate": 0.5,
            "meetsGate": False,
        },
        "structure": {
            "cookTimeMatched": 1,
            "cookTimeTotal": 1,
            "cookTimeAccuracy": 1.0,
            "ingredientPairsMatched": 2,
            "ingredientPairsTotal": 3,
            "ingredientPairRecall": 2 / 3,
            "orderedStepPhrasesMatched": 3,
            "orderedStepPhrasesTotal": 4,
            "orderedStepPhraseRecall": 0.75,
        },
        "latency": {"medianMs": 200, "p95Ms": 300},
        "usage": {
            "extractionInputTokens": 10,
            "extractionOutputTokens": 20,
            "verificationCalls": 1,
            "verificationInputTokens": 5,
            "verificationOutputTokens": 2,
            "normalizationCalls": 1,
            "normalizationInputTokens": 7,
            "normalizationOutputTokens": 3,
            "totalInputTokens": 22,
            "totalOutputTokens": 25,
            "reportedCostUSD": "0.17",
            "reportedCostComplete": False,
            "costPerSuccessfulCaseUSD": None,
        },
    }


def test_pipeline_model_override_applies_to_extraction_and_verification() -> None:
    settings = Settings(
        openrouter_api_key="test-openrouter-key",
        openrouter_model_id="default-model",
        usda_api_key="test-usda-key",
    )

    pipeline = eval_extraction._pipeline(settings, model_id="candidate-model")

    assert settings.openrouter_model_id == "default-model"
    assert pipeline.model_id == "candidate-model"
    assert pipeline.verifier is not None
    assert pipeline.verifier._model_id == "candidate-model"
    assert pipeline.verification_recorder is not None
    assert pipeline.verifier._client is pipeline.verification_recorder


def test_main_passes_explicit_model_to_extraction(monkeypatch) -> None:
    calls: list[tuple[str, str | None, str, str | None]] = []

    def fake_extract(
        label: str,
        only: str | None,
        partition: str,
        model: str | None,
    ) -> None:
        calls.append((label, only, partition, model))

    monkeypatch.setattr(eval_extraction, "extract", fake_extract)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "eval_extraction.py",
            "extract",
            "--corpus",
            "held-out",
            "--label",
            "candidate-run",
            "--model",
            "candidate-model",
        ],
    )

    assert eval_extraction.main() == 0
    assert calls == [("candidate-run", None, "held-out", "candidate-model")]


def test_new_result_path_refuses_to_overwrite_existing_artifact(
    monkeypatch,
    tmp_path: Path,
) -> None:
    monkeypatch.setattr(eval_extraction, "RESULTS", tmp_path)
    existing = tmp_path / "candidate-run.json"
    existing.write_text("known-good")

    try:
        eval_extraction._new_result_path("candidate-run")
    except FileExistsError as error:
        assert str(existing) in str(error)
    else:
        raise AssertionError("expected an existing benchmark artifact to be rejected")

    assert existing.read_text() == "known-good"


def test_new_result_path_rejects_a_label_that_escapes_results() -> None:
    try:
        eval_extraction._new_result_path("../outside-results")
    except ValueError as error:
        assert "label" in str(error)
    else:
        raise AssertionError("expected an unsafe benchmark label to be rejected")


def test_recording_verification_client_captures_and_resets_usage() -> None:
    response = StructuredVerificationResponse(
        parsed_output=VerificationResponse(),
        input_tokens=123,
        output_tokens=45,
        cost_usd=Decimal("0.0123"),
    )

    class StubVerificationClient:
        def propose_patches(self, **_kwargs) -> StructuredVerificationResponse:
            return response

    recorder = eval_extraction.RecordingVerificationClient(
        StubVerificationClient()
    )

    assert recorder.usage == eval_extraction.VerificationUsage()
    returned = recorder.propose_patches(
        model="candidate-model",
        max_tokens=100,
        template=object(),
        issues=[],
        evidence=[],
    )
    assert returned is response
    assert recorder.usage == eval_extraction.VerificationUsage(
        calls=1,
        input_tokens=123,
        output_tokens=45,
        cost_usd=Decimal("0.0123"),
    )

    recorder.reset()

    assert recorder.usage == eval_extraction.VerificationUsage()


def test_recording_verification_client_marks_missing_cost_incomplete() -> None:
    response = StructuredVerificationResponse(
        parsed_output=VerificationResponse(),
        input_tokens=1,
        output_tokens=2,
        cost_usd=None,
    )

    class StubVerificationClient:
        def propose_patches(self, **_kwargs) -> StructuredVerificationResponse:
            return response

    recorder = eval_extraction.RecordingVerificationClient(
        StubVerificationClient()
    )

    recorder.propose_patches(
        model="candidate-model",
        max_tokens=100,
        template=object(),
        issues=[],
        evidence=[],
    )

    assert recorder.usage.reported_cost_complete is False


def test_recording_verification_client_marks_failed_call_incomplete() -> None:
    class FailingVerificationClient:
        def propose_patches(self, **_kwargs) -> StructuredVerificationResponse:
            raise VerificationUnavailable("provider failed")

    recorder = eval_extraction.RecordingVerificationClient(
        FailingVerificationClient()
    )

    try:
        recorder.propose_patches(
            model="candidate-model",
            max_tokens=100,
            template=object(),
            issues=[],
            evidence=[],
        )
    except VerificationUnavailable:
        pass
    else:
        raise AssertionError("expected the provider failure to propagate")

    assert recorder.usage.calls == 1
    assert recorder.usage.reported_cost_complete is False


def test_pipeline_resets_verification_usage_before_each_case() -> None:
    verification_response = StructuredVerificationResponse(
        parsed_output=VerificationResponse(),
        input_tokens=12,
        output_tokens=3,
        cost_usd=Decimal("0.004"),
    )

    class StubVerificationClient:
        def propose_patches(self, **_kwargs) -> StructuredVerificationResponse:
            return verification_response

    recorder = eval_extraction.RecordingVerificationClient(
        StubVerificationClient()
    )
    recorder.propose_patches(
        model="candidate-model",
        max_tokens=100,
        template=object(),
        issues=[],
        evidence=[],
    )

    extraction = RecipeExtraction(
        title="Test recipe",
        description="A test recipe.",
        ingredients=[
            ExtractedIngredient(
                name="salt",
                quantity_text="1 tsp",
                confidence=1,
            )
        ],
        steps=[
            ExtractedStep(
                instruction="Add the salt.",
                ingredient_indices=[0],
                confidence=1,
            )
        ],
    )

    class StubExtractionClient:
        def parse_recipe(self, **_kwargs) -> ClaudeStructuredResponse:
            return ClaudeStructuredResponse(
                stop_reason="end_turn",
                parsed_output=extraction,
                input_tokens=10,
                output_tokens=20,
            )

    class StubNutritionCalculator:
        def enrich(self, template, **_kwargs):
            return template

    corpus = eval_extraction._load_corpus("tuning")
    context = eval_extraction._context(
        corpus.cases[0],
        fixture_version=corpus.fixture_version,
    )
    pipeline = eval_extraction.EvaluationPipeline(
        client=StubExtractionClient(),
        model_id="candidate-model",
        max_tokens=100,
        nutrition=StubNutritionCalculator(),
        verifier=None,
        verification_recorder=recorder,
        nutrition_recorder=None,
    )

    pipeline.run(context)

    assert recorder.usage == eval_extraction.VerificationUsage()


def test_extract_writes_per_case_and_aggregate_benchmark_measurements(
    monkeypatch,
    tmp_path: Path,
    capsys,
) -> None:
    extraction = RecipeExtraction(
        title="Test recipe",
        description="A test recipe.",
        cooking_minutes=20,
        ingredients=[
            ExtractedIngredient(
                name="minutes 20 minutes",
                quantity_text="20",
                confidence=1,
            )
        ],
        steps=[
            ExtractedStep(
                instruction="Preheat oven to 375 ºF.",
                ingredient_indices=[0],
                confidence=1,
            )
        ],
    )
    response = ClaudeStructuredResponse(
        stop_reason="end_turn",
        parsed_output=extraction,
        input_tokens=10,
        output_tokens=20,
        cost_usd=Decimal("0.10"),
    )

    class StubPipeline:
        model_id = "candidate-model"
        verification_recorder = type(
            "Recorder",
            (),
            {
                "usage": eval_extraction.VerificationUsage(
                    calls=1,
                    input_tokens=5,
                    output_tokens=2,
                    cost_usd=Decimal("0.05"),
                )
            },
        )()

        def run(self, context):
            template = eval_extraction.build_reviewed_template(
                extraction,
                context=context,
            )
            return response, extraction, template

    corpus = eval_extraction._load_corpus("held-out")
    reference = corpus.cases[0]
    monkeypatch.setattr(eval_extraction, "RESULTS", tmp_path)
    monkeypatch.setattr(
        eval_extraction,
        "_pipeline",
        lambda _settings, *, model_id: StubPipeline(),
    )

    eval_extraction.extract(
        "candidate-run",
        reference.cache_key,
        "held-out",
        "candidate-model",
    )

    assert (
        f"RUNNING  [1/1] candidate-model {reference.cache_key}"
        in capsys.readouterr().out
    )
    artifact = json.loads((tmp_path / "candidate-run.json").read_text())
    case = artifact["cases"][0]
    assert artifact["runStartedAt"].endswith("Z")
    assert isinstance(case["latencyMs"], int)
    assert case["usage"] == {
        "extractionInputTokens": 10,
        "extractionOutputTokens": 20,
        "extractionCostUSD": "0.10",
        "verificationCalls": 1,
        "verificationInputTokens": 5,
        "verificationOutputTokens": 2,
        "verificationCostUSD": "0.05",
        "normalizationCalls": 0,
        "normalizationInputTokens": 0,
        "normalizationOutputTokens": 0,
        "normalizationCostUSD": "0",
        "reportedCostComplete": True,
    }
    assert artifact["benchmark"]["usage"]["reportedCostUSD"] == "0.15"
    assert artifact["benchmark"]["validStructuredOutputs"]["passed"] == 1
