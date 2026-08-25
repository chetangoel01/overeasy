import json
import sys
from pathlib import Path

from scripts import compare_extraction_models
from tests.unit.evaluation.test_model_comparison import _run


def test_main_writes_a_ranked_machine_readable_comparison(
    monkeypatch,
    tmp_path: Path,
) -> None:
    first = tmp_path / "opus.json"
    second = tmp_path / "cheap.json"
    first.write_text(json.dumps(_run("opus")))
    second.write_text(json.dumps(_run("cheap")))
    monkeypatch.setattr(compare_extraction_models, "RESULTS", tmp_path)
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "compare_extraction_models.py",
            "--label",
            "comparison",
            str(first),
            str(second),
        ],
    )

    assert compare_extraction_models.main() == 0

    artifact = json.loads((tmp_path / "comparison.json").read_text())
    assert artifact["label"] == "comparison"
    assert artifact["sourceLabels"] == ["opus-run-1", "cheap-run-1"]
    assert artifact["qualityLeaderModelID"] in {"opus", "cheap"}
    assert len(artifact["models"]) == 2
