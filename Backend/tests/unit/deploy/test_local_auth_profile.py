from pathlib import Path

import yaml

BACKEND = Path(__file__).parents[3]


def test_local_api_receives_oauth_configuration_and_read_only_apple_key() -> None:
    profile = yaml.safe_load((BACKEND / "docker-compose.yml").read_text())
    environment = profile["services"]["migrate"]["environment"]

    for variable in (
        "LADLE_APPLE_ENABLED",
        "LADLE_APPLE_BUNDLE_ID",
        "LADLE_APPLE_TEAM_ID",
        "LADLE_APPLE_KEY_ID",
        "LADLE_GOOGLE_ENABLED",
        "LADLE_GOOGLE_SERVER_CLIENT_ID",
    ):
        assert variable in environment

    assert environment["LADLE_APPLE_PRIVATE_KEY_FILE"] == (
        "/run/secrets/apple_private_key"
    )
    assert (
        "${LADLE_APPLE_PRIVATE_KEY_FILE:-/dev/null}"
        ":/run/secrets/apple_private_key:ro"
    ) in profile["services"]["api"]["volumes"]
