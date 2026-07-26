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
    # One unit per call, like every other provider. The daily limit counts
    # calls, so billing seconds of audio here would starve it.
    assert result.billed_units == Decimal(1)


def test_transient_service_failure_is_retried_once(tmp_path: Path) -> None:
    calls = 0
    delays: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        del request
        calls += 1
        if calls == 1:
            return httpx.Response(503, json={"error": "temporarily unavailable"})
        return httpx.Response(200, json=VERBOSE)

    result = transcriber(
        handler,
        request_attempts=2,
        sleeper=delays.append,
    ).transcribe(audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1")

    assert result.segments
    assert calls == 2
    assert delays == [1]


def test_empty_transcript_is_not_retried(tmp_path: Path) -> None:
    calls = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal calls
        del request
        calls += 1
        return httpx.Response(200, json={"text": ""})

    with pytest.raises(TranscriptUnavailable):
        transcriber(handler, request_attempts=2).transcribe(
            audio_file(tmp_path),
            job_id=uuid4(),
            source_revision="rev-1",
        )

    assert calls == 1


def _word(text: str, start: float, end: float) -> dict[str, object]:
    return {"word": text, "start": start, "end": end}


def test_word_timings_are_regrouped_into_utterances(tmp_path: Path) -> None:
    """Whisper's 30-second chunks cannot locate a step; word timings can."""

    captured: dict[str, object] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        import json as _json

        captured.update(_json.loads(request.content))
        return httpx.Response(
            200,
            json={
                "text": "Add two cans. Simmer until thick.",
                "language": "en",
                # One coarse chunk covering everything, as the host really
                # returns it.
                "segments": [
                    {"start": 0.0, "end": 30.0, "text": "Add two cans. Simmer..."}
                ],
                "words": [
                    _word("Add", 0.10, 0.30),
                    _word("two", 0.35, 0.55),
                    _word("cans.", 0.60, 2.40),
                    # A clear pause: the creator moved on to the next action.
                    _word("Simmer", 5.00, 5.40),
                    _word("until", 5.45, 5.70),
                    _word("thick.", 5.75, 7.60),
                ],
            },
        )

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert captured["timestamp_granularities"] == ["word", "segment"]
    assert [segment.text for segment in result.segments] == [
        "Add two cans.",
        "Simmer until thick.",
    ]
    assert result.segments[0].start_seconds == 0.10
    assert result.segments[0].end_seconds == 2.40
    assert result.segments[1].start_seconds == 5.00
    assert result.segments[1].end_seconds == 7.60


def test_words_win_over_the_coarse_segment_list(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(
            200,
            json={
                "text": "one two",
                "segments": [{"start": 0.0, "end": 30.0, "text": "one two"}],
                "words": [_word("one", 0.0, 1.0), _word("two.", 1.1, 3.5)],
            },
        )

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert result.segments[0].end_seconds == 3.5


def test_unusable_word_timings_fall_back_to_segments(tmp_path: Path) -> None:
    """A host echoing words without timings must not erase the transcript."""

    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(
            200,
            json={
                **VERBOSE,
                "words": [{"word": "Add"}, {"word": "two", "start": None}],
            },
        )

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert [segment.text for segment in result.segments] == [
        "Add two cans of chickpeas.",
        "Simmer until thick.",
    ]


def test_a_creator_who_never_pauses_still_gets_split(tmp_path: Path) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        del request
        return httpx.Response(
            200,
            json={
                "text": "long",
                "words": [
                    _word(f"word{index}", index * 1.0, index * 1.0 + 0.9)
                    for index in range(40)
                ],
            },
        )

    result = transcriber(handler).transcribe(
        audio_file(tmp_path), job_id=uuid4(), source_revision="rev-1"
    )

    assert len(result.segments) > 1
    for segment in result.segments:
        assert segment.start_seconds is not None
        assert segment.end_seconds is not None
        assert segment.end_seconds - segment.start_seconds <= 15.0


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
