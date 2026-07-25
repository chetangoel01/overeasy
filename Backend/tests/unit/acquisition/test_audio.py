from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4

import httpx
import pytest

from ladle.acquisition.audio import (
    AudioTranscriptProvider,
    WhisperTranscriber,
)
from ladle.acquisition.errors import (
    MalformedProviderResponse,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
    TranscriptUnavailable,
)
from ladle.acquisition.models import SourceVideoDescriptor

VERBOSE = {
    "text": "Add two cans of chickpeas. Simmer until thick.",
    "language": "english",
    "duration": 22.3,
    "segments": [
        {"start": 0.28, "end": 12.0, "text": " Add two cans of chickpeas."},
        {"start": 12.0, "end": 22.3, "text": " Simmer until thick."},
    ],
}


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id="ABC123",
        canonical_url="https://www.instagram.com/reel/ABC123/",
        source_revision="rev-1",
    )


def transcriber(handler: object, **kwargs: object) -> WhisperTranscriber:
    return WhisperTranscriber(
        http=httpx.Client(transport=httpx.MockTransport(handler)),  # type: ignore[arg-type]
        api_key="test-key",
        base_url="https://openrouter.ai/api/v1",
        model_id="openai/whisper-large-v3",
        **kwargs,  # type: ignore[arg-type]
    )


def audio_file(tmp_path: Path, size: int = 2048) -> Path:
    path = tmp_path / "audio.mp3"
    path.write_bytes(b"\xff\xfb" + b"\x00" * (size - 2))
    return path


def test_verbose_json_becomes_timed_generated_evidence(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path.endswith("/audio/transcriptions")
        assert request.headers["Authorization"] == "Bearer test-key"
        return httpx.Response(200, json=VERBOSE)

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert [segment.text for segment in result.segments] == [
        "Add two cans of chickpeas.",
        "Simmer until thick.",
    ]
    assert result.segments[0].start_seconds == 0.28
    assert result.segments[1].end_seconds == 22.3
    # Whisper output is machine transcription, whatever produced the audio.
    assert all(segment.generated for segment in result.segments)
    assert result.segments[0].provenance == "whisper:openai/whisper-large-v3"
    assert result.language == "english"
    assert result.billed_units == Decimal("22.300")


def test_flat_response_keeps_text_without_inventing_timings(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(200, json={"text": "Add two cans of chickpeas."})

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert len(result.segments) == 1
    assert result.segments[0].start_seconds is None
    assert result.segments[0].end_seconds is None


def test_empty_response_is_transcript_unavailable(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(200, json={"text": "", "segments": []})

    with pytest.raises(TranscriptUnavailable):
        transcriber(handler).transcribe(
            audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


def test_oversized_audio_is_refused_before_upload(tmp_path: Path) -> None:
    calls: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append(str(request.url))
        return httpx.Response(200, json=VERBOSE)

    client = transcriber(handler, max_audio_bytes=100)

    with pytest.raises(TranscriptUnavailable):
        client.transcribe(
            audio_file(tmp_path, size=2048), job_id=uuid4(), source_revision="rev-1"
        )
    # Nothing was uploaded, so nothing was billed.
    assert calls == []


@pytest.mark.parametrize(
    ("status", "expected"),
    [
        (401, ProviderAuthenticationError),
        (429, ProviderQuotaError),
        (503, ProviderTransientError),
    ],
)
def test_http_failures_map_to_provider_errors(
    tmp_path: Path, status: int, expected: type[Exception]
) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(status, text="nope")

    with pytest.raises(expected):
        transcriber(handler).transcribe(
            audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


def test_non_json_response_is_malformed(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(200, text="not json")

    with pytest.raises(MalformedProviderResponse):
        transcriber(handler).transcribe(
            audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
        )


class Silent:
    def audio(
        self,
        source: SourceVideoDescriptor,
        *,
        media_url: str | None,
        work_dir: Path,
    ) -> Path | None:
        del source, media_url, work_dir
        return None


class Recording:
    def __init__(self, audio_path: Path) -> None:
        self.audio_path = audio_path
        self.media_urls: list[str | None] = []

    def audio(
        self,
        source: SourceVideoDescriptor,
        *,
        media_url: str | None,
        work_dir: Path,
    ) -> Path | None:
        del source, work_dir
        self.media_urls.append(media_url)
        return self.audio_path


class StubTranscriber:
    def __init__(self) -> None:
        self.calls = 0

    def transcribe(self, audio: Path, *, job_id: UUID, source_revision: str) -> object:
        del audio, job_id, source_revision
        self.calls += 1
        return "transcript"


def test_unavailable_audio_raises_rather_than_billing(tmp_path: Path) -> None:
    stub = StubTranscriber()
    provider = AudioTranscriptProvider(
        audio_source=Silent(),
        transcriber=stub,  # type: ignore[arg-type]
    )

    with pytest.raises(TranscriptUnavailable):
        provider.transcript(source(), job_id=uuid4())
    assert stub.calls == 0


def test_long_video_is_refused_before_any_download(tmp_path: Path) -> None:
    recorder = Recording(audio_file(tmp_path))
    stub = StubTranscriber()
    provider = AudioTranscriptProvider(
        audio_source=recorder,
        transcriber=stub,  # type: ignore[arg-type]
        max_duration_seconds=600,
    )

    with pytest.raises(TranscriptUnavailable):
        provider.transcript(source(), job_id=uuid4(), duration_seconds=3600)
    assert recorder.media_urls == []
    assert stub.calls == 0


def test_media_url_is_passed_through_to_the_audio_source(tmp_path: Path) -> None:
    recorder = Recording(audio_file(tmp_path))
    provider = AudioTranscriptProvider(
        audio_source=recorder,
        transcriber=StubTranscriber(),  # type: ignore[arg-type]
    )

    provider.transcript(
        source(),
        job_id=uuid4(),
        media_url="https://cdn.instagram.com/reel.mp4",
        duration_seconds=57.2,
    )

    assert recorder.media_urls == ["https://cdn.instagram.com/reel.mp4"]
