"""Release, isolation, and startup contracts for the local Docker stack."""

import re
from pathlib import Path
from typing import Any, cast

import yaml
from pydantic import ValidationError

from ladle.config import Settings

BACKEND = Path(__file__).parents[3]


def compose() -> dict[str, Any]:
    return yaml.safe_load((BACKEND / "docker-compose.yml").read_text())


def test_runtime_image_pins_what_it_installs_and_ships_no_secrets() -> None:
    dockerfile = (BACKEND / "Dockerfile").read_text()
    ignored = (BACKEND / ".dockerignore").read_text()

    assert re.search(
        r"^FROM python:3\.12\.\d+-slim-bookworm@sha256:[0-9a-f]{64}$",
        dockerfile,
        re.MULTILINE,
    )
    assert re.search(
        r"^COPY --from=ghcr\.io/astral-sh/uv:\d+\.\d+\.\d+@sha256:[0-9a-f]{64} ",
        dockerfile,
        re.MULTILINE,
    )
    assert "snapshot.debian.org" in dockerfile
    assert "ca-certificates=${CA_CERTIFICATES_VERSION}" in dockerfile
    assert "ffmpeg=${FFMPEG_VERSION}" in dockerfile

    # What a build context must never carry into a pushed image: history,
    # environment files, yt-dlp session cookies and local databases.
    for pattern in (".git", ".env*", "*.cookies*", "*.sqlite*"):
        assert pattern in ignored


def test_local_services_are_sandboxed_and_publish_only_to_loopback() -> None:
    services = compose()["services"]

    # Every service built from this repository, as opposed to a stock image.
    built = {name: value for name, value in services.items() if "image" not in value}
    assert {"api", "worker", "beat", "migrate"} <= set(built)
    for name, service in built.items():
        assert service["read_only"] is True, name
        assert service["cap_drop"] == ["ALL"], name
        assert service["security_opt"] == ["no-new-privileges:true"], name

    for name, service in services.items():
        for port in service.get("ports", []):
            assert port.startswith("127.0.0.1:"), (name, port)


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
