"""Everything the local Docker stack promises, asserted once per file it reads.

This replaces `test_container_hardening.py`, `test_data_service_policy.py` and
`test_local_auth_profile.py`, which between them read `docker-compose.yml` eight
times to assert eight disjoint groups of settings. Every assertion they made
still runs here; they are grouped by the file they are about instead.
"""

import re
from pathlib import Path
from typing import Any, cast

import yaml
from pydantic import ValidationError

from ladle.config import Settings

BACKEND = Path(__file__).parents[3]


def compose_text() -> str:
    return (BACKEND / "docker-compose.yml").read_text()


def compose() -> dict[str, Any]:
    return yaml.safe_load(compose_text())


def test_runtime_image_is_reproducible_and_ships_no_development_artifacts() -> None:
    dockerfile = (BACKEND / "Dockerfile").read_text()
    ignored = (BACKEND / ".dockerignore").read_text()

    assert re.search(
        r"^FROM python:3\.12\.\d+-slim-bookworm@sha256:[0-9a-f]{64}$",
        dockerfile,
        re.MULTILINE,
    )
    assert re.search(
        r"^COPY --from=ghcr\.io/astral-sh/uv:0\.8\.22@sha256:[0-9a-f]{64} ",
        dockerfile,
        re.MULTILINE,
    )
    assert "snapshot.debian.org" in dockerfile
    assert "ca-certificates=${CA_CERTIFICATES_VERSION}" in dockerfile
    assert "ffmpeg=${FFMPEG_VERSION}" in dockerfile
    assert "ARG INSTALL_MEDIA_TOOLS=true" in dockerfile
    assert 'if [ "$INSTALL_MEDIA_TOOLS" = "true" ]' in dockerfile
    assert "INSTALL_MEDIA_TOOLS: ${LADLE_INSTALL_MEDIA_TOOLS:-true}" in compose_text()
    assert "HEALTHCHECK" in dockerfile
    assert 'CMD ["/app/.venv/bin/python", "-m", "ladle.api"]' in dockerfile
    assert dockerfile.count("--mount=type=cache,target=/tmp/ladle/cache/uv") == 2

    for pattern in (
        ".git",
        ".env*",
        "tests",
        "docs",
        "load",
        "docker-compose*",
        ".eval-cache",
        "*.cookies*",
        "*.sqlite*",
        "__pycache__",
    ):
        assert pattern in ignored


def test_local_services_are_sandboxed_recover_and_publish_only_to_loopback() -> None:
    text = compose_text()
    services = compose()["services"]

    assert "x-runtime-security: &runtime-security" in text
    assert text.count("<<: *runtime-security") >= 4
    for requirement in (
        "read_only: true",
        "tmpfs:",
        "cap_drop:",
        '- "ALL"',
        "no-new-privileges:true",
        "pids_limit:",
        "mem_limit:",
        "cpus:",
        "nofile:",
        "fsize:",
    ):
        assert requirement in text

    for service_name in ("api", "worker", "beat"):
        assert services[service_name]["restart"] == "unless-stopped"

    worker = services["worker"]
    assert worker["mem_limit"] == "${LADLE_WORKER_MEMORY_LIMIT:-2g}"
    assert worker["cpus"] == "${LADLE_WORKER_CPU_LIMIT:-2.0}"
    assert "--concurrency=${LADLE_WORKER_CONCURRENCY:-1}" in worker["command"]

    edge = services["device-edge"]
    assert edge["profiles"] == ["device-tunnel"]
    assert edge["ports"] == ["127.0.0.1:4114:8082"]
    assert edge["read_only"] is True
    assert edge["cap_drop"] == ["ALL"]
    assert edge["security_opt"] == ["no-new-privileges:true"]
    assert edge["depends_on"]["api"]["condition"] == "service_healthy"
    assert edge["depends_on"]["minio"]["condition"] == "service_healthy"


def test_local_data_services_and_account_providers_are_configured() -> None:
    text = compose_text()
    services = compose()["services"]

    for option in (
        "--appendonly",
        "--appendfsync",
        "everysec",
        "--maxmemory-policy",
        "noeviction",
        "--stop-writes-on-bgsave-error",
    ):
        assert option in text
    assert "ladle.infrastructure.object_storage_init" in text
    assert "./deploy/object-storage-lifecycle.json:" in text

    environment = services["migrate"]["environment"]
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
        "${LADLE_APPLE_PRIVATE_KEY_FILE:-/dev/null}:/run/secrets/apple_private_key:ro"
    ) in services["api"]["volumes"]


def chaos_overlay() -> dict[str, Any]:
    """Read `deploy/chaos/docker-compose.chaos.yml` the way Compose merges it.

    The overlay uses Compose's `!override` tag, which only changes how a value
    merges over the base file; PyYAML's safe loader rejects unknown tags, so
    it is read here as the plain value it wraps.
    """

    class OverlayLoader(yaml.SafeLoader):
        pass

    def plain_value(loader: yaml.SafeLoader, node: yaml.Node) -> Any:
        if isinstance(node, yaml.SequenceNode):
            return loader.construct_sequence(node)
        if isinstance(node, yaml.MappingNode):
            return loader.construct_mapping(node)
        return loader.construct_scalar(cast(yaml.ScalarNode, node))

    OverlayLoader.add_constructor("!override", plain_value)
    overlay = (BACKEND / "deploy" / "chaos" / "docker-compose.chaos.yml").read_text()
    return cast(dict[str, Any], yaml.load(overlay, Loader=OverlayLoader))


def test_chaos_overlay_pins_keep_the_worker_timing_valid() -> None:
    """Every timing the chaos overlay shrinks must still satisfy Settings.

    `Settings.validate_worker_timing` orders the longest provider timeout below
    the soft task limit, and the overlay pins that limit at 12 s so a broker
    outage resolves inside the drill. A provider timeout that joins the
    validator without a pin here keeps its default, api, worker and beat then
    crash at startup, and `/health/ready` never exists — the scheduled chaos
    job was red from 2026-08-31 because `usda_timeout_seconds` (default 15 s)
    arrived that way.

    The base Compose environment sets no timing variable and the autouse
    fixture clears `LADLE_*`, so the pins over the defaults are exactly what
    the containers validate.
    """
    overlay = chaos_overlay()
    timing = overlay["x-chaos-timing"]
    for service_name in ("api", "worker", "beat"):
        assert overlay["services"][service_name]["environment"] == timing

    pins = {
        name.removeprefix("LADLE_").lower(): value for name, value in timing.items()
    }
    try:
        settings = Settings(_env_file=None, **pins)
    except ValidationError as error:
        raise AssertionError(
            "deploy/chaos/docker-compose.chaos.yml leaves a timing at a default "
            "that Settings rejects; pin every provider timeout the validator "
            f"orders below LADLE_CELERY_TASK_SOFT_TIME_LIMIT_SECONDS: {error}"
        ) from error
    assert settings.usda_timeout_seconds < settings.celery_task_soft_time_limit_seconds
    assert overlay["services"]["api"]["ports"] == ["127.0.0.1:42112:4111"]
    assert overlay["services"]["minio"]["ports"] == []
