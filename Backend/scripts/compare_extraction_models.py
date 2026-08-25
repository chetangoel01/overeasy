"""Compare compatible extraction benchmark artifacts without network access."""

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from ladle.evaluation.model_comparison import ComparisonReport, compare_runs

RESULTS = Path(__file__).resolve().parent.parent / ".eval-cache/results"


def _output_path(label: str) -> Path:
    if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", label) is None:
        raise ValueError("comparison label contains unsafe characters")
    path = RESULTS / f"{label}.json"
    if path.exists():
        raise FileExistsError(f"comparison artifact already exists: {path}")
    return path


def _print_table(report: ComparisonReport) -> None:
    print(
        f"{'model':<40} {'runs':>4} {'gate':>5} {'valid':>7} "
        f"{'nutri':>7} {'ingr':>7} {'steps':>7} {'cook':>7} "
        f"{'cost':>9} {'p50ms':>8} {'p95ms':>8}"
    )
    for model in report.models:
        cost = (
            f"${model.reported_cost_usd_per_run:.4f}"
            if model.reported_cost_usd_per_run is not None
            else "-"
        )
        print(
            f"{model.model_id:<40} {model.run_count:>4} "
            f"{('PASS' if model.eligible else 'FAIL'):>5} "
            f"{model.valid_output_rate:>7.1%} "
            f"{model.nutrition_pass_rate:>7.1%} "
            f"{model.ingredient_pair_recall:>7.1%} "
            f"{model.ordered_step_phrase_recall:>7.1%} "
            f"{model.cook_time_accuracy:>7.1%} {cost:>9} "
            f"{model.median_latency_ms:>8.0f} {model.p95_latency_ms:>8.0f}"
        )


def _load(path: Path) -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(path.read_text()))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    parser.add_argument("results", nargs="+")
    arguments = parser.parse_args()
    runs = [_load(Path(value)) for value in arguments.results]
    report = compare_runs(runs)
    output = report.model_dump(mode="json", by_alias=True)
    output["label"] = arguments.label
    output["sourceLabels"] = [run["label"] for run in runs]
    RESULTS.mkdir(parents=True, exist_ok=True)
    path = _output_path(arguments.label)
    path.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n")
    _print_table(report)
    print(f"\nquality leader: {report.quality_leader_model_id or '-'}")
    print(f"value winner: {report.value_winner_model_id or '-'}")
    print(f"wrote {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
