from pathlib import Path


def test_production_migration_job_is_one_shot_and_gates_rollout() -> None:
    manifest = (
        Path(__file__).parents[3] / "deploy" / "kubernetes" / "migration-job.yaml"
    ).read_text()

    assert "kind: Job" in manifest
    assert '"/app/.venv/bin/alembic", "upgrade", "head"' in manifest
    assert "backoffLimit:" in manifest
    assert "activeDeadlineSeconds:" in manifest
