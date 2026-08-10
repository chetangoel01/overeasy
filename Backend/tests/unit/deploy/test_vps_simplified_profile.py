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

    assert environment["LADLE_ENVIRONMENT"] == "production"
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
    assert "caddy reload" in push


def test_vps_documentation_explains_oauth_backup_and_rollback() -> None:
    runbook = (BACKEND / "docs" / "deployment" / "vps.md").read_text().casefold()

    for topic in (
        "sign in with apple",
        "google oauth",
        "backup",
        "rollback",
        "100 users",
        "/opt/platform/gateway/routes",
    ):
        assert topic in runbook
