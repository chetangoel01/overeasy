"""Everything the local Docker stack promises, asserted once per file it reads.

This replaces `test_container_hardening.py`, `test_data_service_policy.py` and
`test_local_auth_profile.py`, which between them read `docker-compose.yml` eight
times to assert eight disjoint groups of settings. Every assertion they made
still runs here; they are grouped by the file they are about instead.
"""

import re
from pathlib import Path
from typing import Any

import yaml

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
