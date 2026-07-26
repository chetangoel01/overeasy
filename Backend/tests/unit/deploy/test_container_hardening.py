import re
from pathlib import Path

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
