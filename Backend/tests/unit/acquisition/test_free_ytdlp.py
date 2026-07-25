import json
import subprocess

import pytest

from ladle.acquisition.errors import (
    MalformedProviderResponse,
    PrivateOrDeleted,
    ProviderTransientError,
    ProviderUnavailable,
)
from ladle.acquisition.free import ytdlp
from ladle.acquisition.free.ytdlp import YtDlpClient, parse_vtt

MANUAL_VTT = """WEBVTT
Kind: captions
Language: en-US

00:00:00.000 --> 00:00:03.520
Start by chopping two big onions.

00:00:03.520 --> 00:00:09.100
Then add 2 cups of orzo and simmer for ten minutes.
"""

ROLLING_VTT = """WEBVTT

00:00:01.000 --> 00:00:02.500
add the garlic

00:00:02.500 --> 00:00:04.000
add the garlic and the chilli
"""


class Runner:
    def __init__(self, *results: subprocess.CompletedProcess[str] | Exception) -> None:
        self.results = list(results)
        self.commands: list[list[str]] = []

    def __call__(
        self, command: list[str], *, timeout: float
    ) -> subprocess.CompletedProcess[str]:
        del timeout
        self.commands.append(command)
        value = self.results.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


def completed(
    stdout: str = "", stderr: str = "", returncode: int = 0
) -> subprocess.CompletedProcess[str]:
    return subprocess.CompletedProcess(
        args=["yt-dlp"], returncode=returncode, stdout=stdout, stderr=stderr
    )


def test_parse_vtt_preserves_cue_timing() -> None:
    segments = parse_vtt(MANUAL_VTT, generated=False, language="en-US")

    assert len(segments) == 1
    assert segments[0].start_seconds == 0.0
    assert segments[0].end_seconds == pytest.approx(9.1)
    assert "chopping two big onions" in segments[0].text
    assert "2 cups of orzo" in segments[0].text
    assert segments[0].generated is False
    assert segments[0].provenance == "ytdlp:manual:en-US"


def test_parse_vtt_strips_rolling_caption_prefixes() -> None:
    segments = parse_vtt(ROLLING_VTT, generated=True, language="en")

    assert segments[0].text == "add the garlic and the chilli"
    assert segments[0].generated is True


def test_metadata_reads_languages_and_prefers_manual_captions() -> None:
    payload = {
        "title": "Creamy Garlic-Lemon Chickpeas",
        "description": "2 16oz cans of chickpeas, drained",
        "uploader": "mishkamakesfood",
        "duration": 22,
        "subtitles": {"en-US": [{}]},
        "automatic_captions": {"en-orig": [{}], "en": [{}]},
    }
    client = YtDlpClient(binary="yt-dlp", runner=Runner(completed(json.dumps(payload))))

    media = client.metadata("https://www.tiktok.com/@mishkamakesfood/video/1")

    assert media.metadata.title == "Creamy Garlic-Lemon Chickpeas"
    assert media.metadata.creator_name == "mishkamakesfood"
    assert media.metadata.duration_seconds == 22
    track = media.preferred_track()
    assert track is not None
    assert track.language == "en-US"
    assert track.generated is False


def test_metadata_falls_back_to_generated_captions() -> None:
    payload = {"title": "x", "description": "", "automatic_captions": {"en": [{}]}}
    client = YtDlpClient(binary="yt-dlp", runner=Runner(completed(json.dumps(payload))))

    track = client.metadata("https://example.com/v").preferred_track()

    assert track is not None
    assert track.generated is True


def test_deleted_video_raises_private_or_deleted() -> None:
    client = YtDlpClient(
        binary="yt-dlp",
        runner=Runner(completed(stderr="ERROR: Video unavailable", returncode=1)),
    )

    with pytest.raises(PrivateOrDeleted):
        client.metadata("https://www.youtube.com/watch?v=gone")


def test_login_wall_is_unavailable_not_deleted() -> None:
    client = YtDlpClient(
        binary="yt-dlp",
        runner=Runner(
            completed(
                stderr="ERROR: Sign in to confirm you are not a bot", returncode=1
            )
        ),
    )

    with pytest.raises(ProviderUnavailable) as error:
        client.metadata("https://www.tiktok.com/@a/video/1")
    assert not isinstance(error.value, PrivateOrDeleted)


def test_timeout_is_transient() -> None:
    client = YtDlpClient(
        binary="yt-dlp",
        runner=Runner(subprocess.TimeoutExpired(cmd="yt-dlp", timeout=90)),
    )

    with pytest.raises(ProviderTransientError):
        client.metadata("https://example.com/v")


def test_non_json_output_is_malformed() -> None:
    client = YtDlpClient(binary="yt-dlp", runner=Runner(completed("not json")))

    with pytest.raises(MalformedProviderResponse):
        client.metadata("https://example.com/v")


def test_missing_binary_reports_unavailable(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(ytdlp, "_discover_binary", lambda: None)
    client = YtDlpClient(binary=None, runner=Runner())

    assert client.available is False
    with pytest.raises(ProviderUnavailable):
        client.metadata("https://example.com/v")


def test_binary_is_discovered_beside_the_interpreter() -> None:
    assert YtDlpClient(runner=Runner()).available is True
