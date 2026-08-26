import re
from pathlib import Path

import yaml

BACKEND = Path(__file__).parents[3]


def test_runtime_image_is_reproducible_and_has_a_healthcheck() -> None:
    dockerfile = (BACKEND / "Dockerfile").read_text()

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
    compose = (BACKEND / "docker-compose.yml").read_text()
    assert "INSTALL_MEDIA_TOOLS: ${LADLE_INSTALL_MEDIA_TOOLS:-true}" in compose
    assert "HEALTHCHECK" in dockerfile
    assert 'CMD ["/app/.venv/bin/python", "-m", "ladle.api"]' in dockerfile
    assert dockerfile.count("--mount=type=cache,target=/tmp/ladle/cache/uv") == 2


def test_runtime_services_have_bounded_read_only_sandboxes() -> None:
    compose = (BACKEND / "docker-compose.yml").read_text()

    assert "x-runtime-security: &runtime-security" in compose
    assert compose.count("<<: *runtime-security") >= 4
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
        assert requirement in compose


def test_local_long_running_services_recover_and_worker_avoids_memory_overlap() -> None:
    compose = yaml.safe_load((BACKEND / "docker-compose.yml").read_text())
    services = compose["services"]

    for service_name in ("api", "worker", "beat"):
        assert services[service_name]["restart"] == "unless-stopped"

    worker = services["worker"]
    assert worker["mem_limit"] == "${LADLE_WORKER_MEMORY_LIMIT:-2g}"
    assert worker["cpus"] == "${LADLE_WORKER_CPU_LIMIT:-2.0}"
    assert "--concurrency=${LADLE_WORKER_CONCURRENCY:-1}" in worker["command"]


def test_production_context_excludes_development_and_private_artifacts() -> None:
    ignored = (BACKEND / ".dockerignore").read_text()

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
