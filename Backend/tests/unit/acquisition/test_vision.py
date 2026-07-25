"""Watching the video is the last evidence a silent recipe has."""

from pathlib import Path
from uuid import uuid4

import httpx
import pytest

from ladle.acquisition.errors import (
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
    VisualAnalysisUnavailable,
)
from ladle.acquisition.models import SourceVideoDescriptor
from ladle.acquisition.vision import (
    FrameSampler,
    VisionObserver,
    VisionVisualProvider,
)

DESCRIBED = (
    '[{"frame": 0, "text": "Rice paper is dipped in water."},'
    ' {"frame": 2, "text": "Feta and spinach are spooned onto the sheet."}]'
)


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="tiktok",
        platform_video_id="silent",
        canonical_url="https://www.tiktok.com/@shicocooks/video/1",
        source_revision="rev-1",
    )


def observer(handler: object, **kwargs: object) -> VisionObserver:
    return VisionObserver(
        http=httpx.Client(transport=httpx.MockTransport(handler)),  # type: ignore[arg-type]
        api_key="test-key",
        base_url="https://openrouter.ai/api/v1",
        model_id="google/gemini-2.5-flash",
        **kwargs,  # type: ignore[arg-type]
    )


def frames(tmp_path: Path, count: int = 3) -> list[tuple[float, Path]]:
    made: list[tuple[float, Path]] = []
    for index in range(count):
        path = tmp_path / f"frame{index}.jpg"
        path.write_bytes(b"\xff\xd8\xff" + bytes([index]) * 32)
        made.append((index * 2.5, path))
    return made


def reply(text: str) -> object:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/chat/completions")
        return httpx.Response(200, json={"choices": [{"message": {"content": text}}]})

    return handler


def test_frames_become_timestamped_observations(tmp_path: Path) -> None:
    result = observer(reply(DESCRIBED)).observe(
        frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert [value.text for value in result.observations] == [
        "Rice paper is dipped in water.",
        "Feta and spinach are spooned onto the sheet.",
    ]
    # The frame index is what makes the observation locatable in the video.
    assert result.observations[0].timestamp_seconds == 0.0
    assert result.observations[1].timestamp_seconds == 5.0
    assert result.observations[0].provenance == "vision:google/gemini-2.5-flash"
    assert result.billed_units == 1


def test_a_reply_wrapped_in_a_code_fence_is_still_read(tmp_path: Path) -> None:
    fenced = f"```json\n{DESCRIBED}\n```"

    result = observer(reply(fenced)).observe(
        frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert len(result.observations) == 2


def test_a_frame_index_we_did_not_send_carries_no_timestamp(tmp_path: Path) -> None:
    """Better an untimed observation than one claiming a moment we never saw."""

    payload = '[{"frame": 99, "text": "Something happens."}]'

    result = observer(reply(payload)).observe(
        frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert result.observations[0].timestamp_seconds is None


def test_describing_nothing_is_unavailable_not_an_empty_success(
    tmp_path: Path,
) -> None:
    with pytest.raises(VisualAnalysisUnavailable):
        observer(reply("[]")).observe(
            frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


def test_unparseable_reply_is_unavailable(tmp_path: Path) -> None:
    with pytest.raises(VisualAnalysisUnavailable):
        observer(reply("I cannot see the frames.")).observe(
            frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


def test_no_frames_never_reaches_the_provider(tmp_path: Path) -> None:
    del tmp_path

    def handler(request: httpx.Request) -> httpx.Response:  # pragma: no cover
        raise AssertionError("must not call the provider with nothing to show")

    with pytest.raises(VisualAnalysisUnavailable):
        observer(handler).observe([], job_id=uuid4(), source_revision="rev-1")


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (401, ProviderAuthenticationError),
        (429, ProviderQuotaError),
        (503, ProviderTransientError),
    ],
)
def test_http_failures_map_to_provider_errors(
    status: int, expected: type[Exception], tmp_path: Path
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(status, text="nope")

    with pytest.raises(expected):
        observer(handler).observe(
            frames(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


class Media:
    def __init__(self, path: Path | None) -> None:
        self.path = path
        self.calls: list[str | None] = []

    def media(
        self,
        source: SourceVideoDescriptor,
        *,
        media_url: str | None,
        work_dir: Path,
    ) -> Path | None:
        del source, work_dir
        self.calls.append(media_url)
        return self.path


def test_media_we_cannot_fetch_is_unavailable(tmp_path: Path) -> None:
    provider = VisionVisualProvider(
        media_source=Media(None),
        sampler=FrameSampler(ffmpeg_path="/usr/bin/ffmpeg"),
        observer=observer(reply(DESCRIBED)),
    )

    with pytest.raises(VisualAnalysisUnavailable):
        provider.visual(source(), job_id=uuid4(), media_url=None)


def test_without_ffmpeg_nothing_is_downloaded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No point spending a download on frames we have no way to cut."""

    monkeypatch.setattr("ladle.acquisition.vision.shutil.which", lambda _: None)
    media = Media(tmp_path / "video.mp4")
    provider = VisionVisualProvider(
        media_source=media,
        sampler=FrameSampler(),
        observer=observer(reply(DESCRIBED)),
    )

    with pytest.raises(VisualAnalysisUnavailable):
        provider.visual(source(), job_id=uuid4())
    assert media.calls == []


def test_frames_are_spread_across_the_whole_clip(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Bunched at the start they would describe a title card, not a method."""

    recorded: list[list[str]] = []

    def fake_run(command: list[str], **kwargs: object) -> object:
        recorded.append(command)
        for index in range(4):
            (tmp_path / f"frame{index:03d}.jpg").write_bytes(b"\xff\xd8\xff")

        class Result:
            returncode = 0
            stderr = ""

        return Result()

    monkeypatch.setattr("ladle.acquisition.vision.subprocess.run", fake_run)
    sampler = FrameSampler(ffmpeg_path="/usr/bin/ffmpeg", max_frames=4)

    sampled = sampler.frames(
        tmp_path / "video.mp4",
        work_dir=tmp_path,
        duration_seconds=60,
    )

    # 60s over 4 frames is one every 15s, and the timestamps say so.
    assert "fps=1/15.000" in " ".join(recorded[0])
    assert [time for time, _ in sampled] == [0.0, 15.0, 30.0, 45.0]


def test_a_very_short_clip_does_not_ask_for_sub_second_frames(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    recorded: list[list[str]] = []

    def fake_run(command: list[str], **kwargs: object) -> object:
        recorded.append(command)
        (tmp_path / "frame000.jpg").write_bytes(b"\xff\xd8\xff")

        class Result:
            returncode = 0
            stderr = ""

        return Result()

    monkeypatch.setattr("ladle.acquisition.vision.subprocess.run", fake_run)
    FrameSampler(ffmpeg_path="/usr/bin/ffmpeg", max_frames=8).frames(
        tmp_path / "video.mp4",
        work_dir=tmp_path,
        duration_seconds=3,
    )

    assert "fps=1/1.000" in " ".join(recorded[0])
