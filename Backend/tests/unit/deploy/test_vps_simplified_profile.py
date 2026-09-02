from pathlib import Path

import yaml

BACKEND = Path(__file__).parents[3]
VPS = BACKEND / "deploy" / "vps"
PROFILE = VPS / "docker-compose.yml"


def compose() -> dict[str, object]:
    return yaml.safe_load(PROFILE.read_text())


def test_vps_runtime_is_right_sized_for_one_small_host() -> None:
    services = compose()["services"]

    assert set(services) == {
        "postgres",
        "redis",
        "minio",
        "minio-init",
        "migrate",
        "api",
        "worker",
    }
    assert "--workers" in services["api"]["command"]
    assert "2" in services["api"]["command"]
    assert "--beat" in services["worker"]["command"]
    assert "--concurrency=4" in services["worker"]["command"]
    assert all("ports" not in service for service in services.values())
    assert compose()["x-app"]["build"]["context"] == "."


def test_runtime_healthchecks_are_fast_at_start_then_back_off() -> None:
    services = compose()["services"]
    api_healthcheck = services["api"]["healthcheck"]

    assert "/health/live" in api_healthcheck["test"][-1]
    assert "/health/ready" not in api_healthcheck["test"][-1]
    for name in ("postgres", "redis", "minio", "api", "worker"):
        healthcheck = services[name]["healthcheck"]
        assert healthcheck["interval"] == "5m", name
        assert healthcheck["retries"] == 3, name
        assert healthcheck["start_period"] == "1m", name
        assert healthcheck["start_interval"] == "5s", name


def test_shared_gateway_connects_directly_to_api_and_private_media() -> None:
    profile = compose()
    services = profile["services"]
    route = (VPS / "gateway" / "routes" / "ladle.caddy").read_text()

    assert services["api"]["networks"]["platform"]["aliases"] == ["ladle-api"]
    assert services["minio"]["networks"]["platform"]["aliases"] == ["ladle-minio"]
    assert profile["networks"]["platform"] == {
        "external": True,
        "name": "platform-edge",
    }
    assert "ladle-api:4111" in route
    assert "ladle-minio:9000" in route
    assert "ladle-edge" not in route


def test_deployment_contract_requires_oauth_configuration() -> None:
    environment = compose()["x-ladle-environment"]
    example = (VPS / "env.example").read_text()

    assert environment["LADLE_ENVIRONMENT"] == "${LADLE_ENVIRONMENT:-production}"
    variables = {
        "LADLE_APPLE_ENABLED": "LADLE_APPLE_ENABLED",
        "LADLE_APPLE_BUNDLE_ID": "LADLE_APPLE_BUNDLE_ID",
        "LADLE_APPLE_TEAM_ID": "LADLE_APPLE_TEAM_ID",
        "LADLE_APPLE_KEY_ID": "LADLE_APPLE_KEY_ID",
        "LADLE_APPLE_PRIVATE_KEY_FILE": "LADLE_APPLE_PRIVATE_KEY_PATH",
        "LADLE_GOOGLE_ENABLED": "LADLE_GOOGLE_ENABLED",
        "LADLE_GOOGLE_SERVER_CLIENT_ID": "LADLE_GOOGLE_SERVER_CLIENT_ID",
    }
    for runtime_variable, setup_variable in variables.items():
        assert runtime_variable in environment
        assert setup_variable in example
    assert environment["LADLE_APPLE_ENABLED"] == "true"
    assert environment["LADLE_GOOGLE_ENABLED"] == "true"


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


def test_vps_forces_text_only_extraction() -> None:
    environment = compose()["x-ladle-environment"]
    example = (VPS / "env.example").read_text()

    assert environment["LADLE_FRAME_ANALYSIS_ENABLED"] == "false"
    assert environment["LADLE_THUMBNAIL_ANALYSIS_ENABLED"] == "false"
    assert "LADLE_FRAME_ANALYSIS_ENABLED=false" in example
    assert "LADLE_THUMBNAIL_ANALYSIS_ENABLED=false" in example


def test_vps_supplies_usda_nutrition_configuration() -> None:
    environment = compose()["x-ladle-environment"]
    example = (VPS / "env.example").read_text()

    assert environment["LADLE_USDA_NUTRITION_ENABLED"] == "true"
    assert "LADLE_USDA_API_KEY" in environment
    assert "LADLE_USDA_API_KEY=change-me" in example


def test_vps_operations_stay_small_and_cover_the_real_recovery_contract() -> None:
    scripts = sorted(VPS.glob("*.sh"))
    script_lines = sum(len(script.read_text().splitlines()) for script in scripts)
    manage = (VPS / "manage.sh").read_text()
    push = (VPS / "push.sh").read_text()

    assert {script.name for script in scripts} == {"manage.sh", "push.sh"}
    assert script_lines < 500
    for command in ("deploy", "health", "status", "logs", "backup"):
        assert command in manage
    assert "pg_dump" in manage
    assert "sha256sum" in manage
    assert "archive --format=tar.gz" in push
    assert "manage.sh deploy" in push
    assert "apple_private_key_value" in manage
    assert "--project-name platform-gateway" in push
    assert "--env-file /etc/platform/gateway.env" in push
    assert "caddy reload" in push
