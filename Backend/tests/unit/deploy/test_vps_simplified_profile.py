from pathlib import Path

import yaml

BACKEND = Path(__file__).parents[3]
VPS = BACKEND / "deploy" / "vps"
PROFILE = VPS / "docker-compose.yml"


def compose() -> dict[str, object]:
    return yaml.safe_load(PROFILE.read_text())


def test_vps_services_publish_no_host_ports() -> None:
    # The shared gateway reaches the API over a Docker network. A published
    # port would put Postgres, Redis or MinIO on the host's public interface.
    services = compose()["services"]

    assert all("ports" not in service for service in services.values())


def test_api_healthcheck_probes_liveness_not_readiness() -> None:
    # A readiness probe would mark the API unhealthy whenever a dependency
    # blips, and everything that waits on `service_healthy` with it.
    healthcheck = compose()["services"]["api"]["healthcheck"]

    assert "/health/live" in healthcheck["test"][-1]
    assert "/health/ready" not in healthcheck["test"][-1]


def test_guarded_internal_beta_can_disable_app_attest() -> None:
    environment = compose()["x-ladle-environment"]
    example = (VPS / "env.example").read_text()

    assert environment["LADLE_ENVIRONMENT"] == "${LADLE_ENVIRONMENT:-production}"
    assert environment["LADLE_ATTESTATION_ENFORCED"] == (
        "${LADLE_ATTESTATION_ENFORCED:-true}"
    )
    assert environment["LADLE_APP_ATTEST_ENVIRONMENT"] == (
        "${LADLE_APP_ATTEST_ENVIRONMENT:-production}"
    )
    assert environment["LADLE_INTERACTIVE_DOCS_ENABLED"] == (
        "${LADLE_INTERACTIVE_DOCS_ENABLED:-false}"
    )
    assert "LADLE_ENVIRONMENT=production" in example
    assert "LADLE_INTERACTIVE_DOCS_ENABLED=false" in example
    assert "LADLE_ATTESTATION_ENFORCED=true" in example
    assert "LADLE_APP_ATTEST_ENVIRONMENT=production" in example
