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
        'pytest -q -m "not live_provider and not chaos"',
        "test_migrations.py",
        "git diff --check",
        "pip-audit",
        "gitleaks",
        "trivy",
        "sbom",
        "provenance",
        "cosign sign",
        "restore_drill.py",
    ):
        assert gate in workflow
    assert "ladle-backend:${{ github.sha }}" in workflow
    assert re.search(r"grafana/k6@sha256:[0-9a-f]{64}", workflow)


def test_ci_pins_every_third_party_action_to_a_commit() -> None:
    workflow = (REPOSITORY / ".github" / "workflows" / "backend-ci.yml").read_text()
    action_references = re.findall(r"uses:\s+([^\s]+)", workflow)

    assert action_references
    assert all(
        re.fullmatch(r"[^@]+@[0-9a-f]{40}", reference)
        for reference in action_references
    )


def test_verification_harnesses_cover_load_chaos_and_external_security() -> None:
    load_test = (BACKEND / "load" / "k6-production.js").read_text()
    chaos_test = (
        BACKEND / "tests" / "chaos" / "test_worker_and_broker_recovery.py"
    ).read_text()
    staging_check = (BACKEND / "scripts" / "verify_staging.py").read_text()

    for scenario in (
        "guest_creation",
        "import_bursts",
        "sync_polling",
        "recipe_graph_limits",
    ):
        assert scenario in load_test
    assert "SIGKILL" in chaos_test
    assert "broker_outage" in chaos_test
    for check in (
        "Strict-Transport-Security",
        "Retry-After",
        "requestTooLarge",
        "cloud metadata",
        "openapi.json",
    ):
        assert check in staging_check


def test_pytest_is_newer_than_the_audited_minimum() -> None:
    pyproject = (BACKEND / "pyproject.toml").read_text()

    assert '"pytest>=9.0.3,<10"' in pyproject
