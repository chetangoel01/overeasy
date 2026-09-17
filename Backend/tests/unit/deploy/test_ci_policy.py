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
    assert workflow.count("scanners: vuln") == 4
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


def test_load_profile_still_covers_every_capacity_scenario() -> None:
    """The k6 profile is the only place these scenarios are named.

    The chaos and staging-verifier halves of this test used to assert that
    those files contained certain words; `tests/chaos/` and
    `tests/unit/deploy/test_staging_verifier.py` run that code instead.
    """
    load_test = (BACKEND / "load" / "k6-production.js").read_text()
    workflow = (REPOSITORY / ".github" / "workflows" / "backend-ci.yml").read_text()

    # k6's setup() needs a warm API: the step polls the API's own readiness
    # between starting the stack and running the profile.
    started = workflow.index("docker compose up -d --build")
    ready = workflow.index("http://127.0.0.1:4112/health/ready")
    assert started < ready < workflow.index("run /load/k6-production.js")

    for scenario in (
        "guest_creation",
        "import_bursts",
        "sync_polling",
        "recipe_graph_limits",
    ):
        assert scenario in load_test
