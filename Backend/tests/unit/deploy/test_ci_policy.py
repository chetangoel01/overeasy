import re
from pathlib import Path

BACKEND = Path(__file__).parents[3]
REPOSITORY = BACKEND.parent


def test_ci_enforces_quality_security_migrations_and_exact_image_release() -> None:
    workflow = (REPOSITORY / ".github" / "workflows" / "backend-ci.yml").read_text()

    for gate in (
        "ruff format --check",
        "ruff check",
        "mypy --strict",
        "uv run pytest -q",
        "git diff --check",
        "pip-audit",
        "gitleaks",
        "trivy",
        "sbom",
        "provenance",
        "cosign sign",
    ):
        assert gate in workflow
    # The migration check and the pg_dump restore drill used to be steps of
    # their own that re-ran work the suite already does. They are gates now
    # only because the default selection carries them.
    pyproject = (BACKEND / "pyproject.toml").read_text()
    assert "-m 'not live_provider and not chaos'" in pyproject
    for covered in (
        "tests/integration/test_migrations.py",
        "tests/integration/operations/test_restore_drill.py",
    ):
        assert (BACKEND / covered).exists()
    for image in (
        "ladle-backend:${{ github.sha }}",
        "ladle-worker-egress:${{ github.sha }}",
        "ladle-mac-edge:${{ github.sha }}",
    ):
        assert image in workflow
    assert "ladle-mac-infrastructure-sboms" in workflow
    assert re.search(r"grafana/k6@sha256:[0-9a-f]{64}", workflow)


def test_ci_pins_every_third_party_action_to_a_commit() -> None:
    workflow = (REPOSITORY / ".github" / "workflows" / "backend-ci.yml").read_text()
    action_references = re.findall(r"uses:\s+([^\s]+)", workflow)

    assert action_references
    assert all(
        re.fullmatch(r"[^@]+@[0-9a-f]{40}", reference)
        for reference in action_references
    )
