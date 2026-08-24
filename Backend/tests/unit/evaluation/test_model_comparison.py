from copy import deepcopy
from decimal import Decimal

import pytest

from ladle.evaluation.model_comparison import compare_runs


def _run(model: str) -> dict[str, object]:
    return {
        "corpusName": "text-only-held-out",
        "fixtureVersion": "public-domain-v1",
        "partition": "heldOut",
        "referenceStatus": "verified",
        "corpusDigest": "sha256:locked",
        "promptVersion": "recipe-v11",
        "modelVersion": model,
        "label": f"{model}-run-1",
        "visualProviderCalls": 0,
        "cases": [{} for _ in range(80)],
        "wholeRecipeNutrition": {
            "passed": 76,
            "total": 80,
            "passRate": "0.95",
            "meetsGate": True,
        },
        "sparseSafety": {
            "passed": 20,
            "total": 20,
            "meetsGate": True,
            "cases": [],
        },
        "benchmark": {
            "validStructuredOutputs": {
                "passed": 80,
                "total": 80,
                "passRate": 1.0,
                "meetsGate": True,
            },
            "structure": {
                "cookTimeMatched": 72,
                "cookTimeTotal": 80,
                "cookTimeAccuracy": 0.9,
                "ingredientPairsMatched": 900,
                "ingredientPairsTotal": 1000,
                "ingredientPairRecall": 0.9,
                "orderedStepPhrasesMatched": 450,
                "orderedStepPhrasesTotal": 500,
                "orderedStepPhraseRecall": 0.9,
            },
            "latency": {"medianMs": 1000, "p95Ms": 2000},
            "usage": {
                "extractionInputTokens": 1000,
                "extractionOutputTokens": 500,
                "verificationCalls": 10,
                "verificationInputTokens": 100,
                "verificationOutputTokens": 50,
                "totalInputTokens": 1100,
                "totalOutputTokens": 550,
                "reportedCostUSD": "10",
                "reportedCostComplete": True,
                "costPerSuccessfulCaseUSD": "0.125",
            },
        },
    }


def test_compare_runs_rejects_a_different_prompt_version() -> None:
    first = _run("first")
    second = deepcopy(_run("second"))
    second["promptVersion"] = "recipe-v12"

    with pytest.raises(ValueError, match="promptVersion"):
        compare_runs([first, second])


def test_compare_runs_rejects_a_summary_with_the_wrong_case_total() -> None:
    first = _run("first")
    second = deepcopy(_run("second"))
    second["benchmark"]["validStructuredOutputs"]["total"] = 79

    with pytest.raises(ValueError, match=r"validStructuredOutputs\.total"):
        compare_runs([first, second])


def test_compare_runs_rejects_a_nutrition_summary_missing_a_case() -> None:
    first = _run("first")
    second = deepcopy(_run("second"))
    second["wholeRecipeNutrition"].update(
        {"total": 79, "passRate": "0.9620253165"}
    )

    with pytest.raises(ValueError, match=r"wholeRecipeNutrition\.total"):
        compare_runs([first, second])


def test_compare_runs_rejects_duplicate_run_labels() -> None:
    first = _run("first")
    duplicate = deepcopy(first)

    with pytest.raises(ValueError, match="duplicate label"):
        compare_runs([first, duplicate])


def test_compare_runs_uses_price_only_inside_the_quality_equivalence_band() -> None:
    opus = _run("opus")
    cheap = deepcopy(_run("cheap"))
    cheap["benchmark"]["structure"].update(
        {
            "cookTimeMatched": 895,
            "cookTimeTotal": 1000,
            "cookTimeAccuracy": 0.895,
            "ingredientPairsMatched": 895,
            "ingredientPairsTotal": 1000,
            "ingredientPairRecall": 0.895,
            "orderedStepPhrasesMatched": 895,
            "orderedStepPhrasesTotal": 1000,
            "orderedStepPhraseRecall": 0.895,
        }
    )
    cheap["benchmark"]["usage"].update(
        {
            "reportedCostUSD": "1",
            "costPerSuccessfulCaseUSD": "0.0125",
        }
    )
    cheaper_but_worse = deepcopy(_run("cheaper-but-worse"))
    cheaper_but_worse["benchmark"]["structure"].update(
        {
            "ingredientPairsMatched": 850,
            "ingredientPairRecall": 0.85,
        }
    )
    cheaper_but_worse["benchmark"]["usage"].update(
        {
            "reportedCostUSD": "0.50",
            "costPerSuccessfulCaseUSD": "0.00625",
        }
    )

    report = compare_runs([opus, cheap, cheaper_but_worse])

    assert report.quality_leader_model_id == "opus"
    assert report.comparable_quality_model_ids == ["opus", "cheap"]
    assert report.value_winner_model_id == "cheap"


def test_incomplete_cost_is_not_used_for_the_value_winner() -> None:
    opus = _run("opus")
    unpriced = deepcopy(_run("unpriced"))
    unpriced["benchmark"]["usage"].update(
        {
            "reportedCostUSD": "0.01",
            "reportedCostComplete": False,
            "costPerSuccessfulCaseUSD": None,
        }
    )

    report = compare_runs([opus, unpriced])

    assert "unpriced" in report.comparable_quality_model_ids
    assert report.value_winner_model_id == "opus"


def test_compare_runs_groups_repeats_and_requires_every_run_to_pass() -> None:
    opus = _run("opus")
    cheap_first = _run("cheap")
    cheap_repeat = deepcopy(_run("cheap"))
    cheap_repeat["label"] = "cheap-run-2"
    cheap_repeat["sparseSafety"].update(
        {"passed": 19, "meetsGate": False}
    )
    cheap_repeat["benchmark"]["structure"].update(
        {
            "ingredientPairsMatched": 800,
            "ingredientPairRecall": 0.8,
        }
    )

    report = compare_runs([opus, cheap_first, cheap_repeat])
    cheap = next(model for model in report.models if model.model_id == "cheap")

    assert cheap.run_count == 2
    assert cheap.eligible is False
    assert cheap.gate_failures == ["sparseSafety"]
    assert cheap.ingredient_pair_recall == Decimal("0.85")
    assert cheap.ingredient_pair_recall_range.minimum == Decimal("0.8")
    assert cheap.ingredient_pair_recall_range.maximum == Decimal("0.9")
    assert report.quality_leader_model_id == "opus"


def test_sparse_gate_requires_all_twenty_safety_cases() -> None:
    opus = _run("opus")
    incomplete = deepcopy(_run("incomplete"))
    incomplete["sparseSafety"].update(
        {"passed": 19, "total": 19, "meetsGate": True}
    )

    report = compare_runs([opus, incomplete])
    summary = next(
        model for model in report.models if model.model_id == "incomplete"
    )

    assert summary.eligible is False
    assert summary.gate_failures == ["sparseSafety"]


def test_valid_output_gate_is_derived_from_counts() -> None:
    opus = _run("opus")
    unreliable = deepcopy(_run("unreliable"))
    unreliable["benchmark"]["validStructuredOutputs"].update(
        {"passed": 70, "passRate": 0.875, "meetsGate": True}
    )

    report = compare_runs([opus, unreliable])
    summary = next(
        model for model in report.models if model.model_id == "unreliable"
    )

    assert summary.eligible is False
    assert summary.gate_failures == ["validStructuredOutputs"]


def test_nutrition_gate_is_derived_from_counts() -> None:
    opus = _run("opus")
    inaccurate = deepcopy(_run("inaccurate"))
    inaccurate["wholeRecipeNutrition"].update(
        {"passed": 70, "passRate": "0.875", "meetsGate": True}
    )

    report = compare_runs([opus, inaccurate])
    summary = next(
        model for model in report.models if model.model_id == "inaccurate"
    )

    assert summary.eligible is False
    assert summary.gate_failures == ["wholeRecipeNutrition"]
