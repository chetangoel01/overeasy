"""The last resort before the expensive providers: transcribe the audio.

Every rung above this is free, and after this session's work most videos never
reach it. What is left are the genuinely hard ones — an Instagram reel, which
publishes no transcript at all, or a TikTok whose creator disabled captions.

Audio is fetched from whatever route the platform allows, downsampled hard
(16 kHz mono, 32 kbps) because speech recognition does not benefit from more,
and sent to a Whisper endpoint. A minute of audio costs a fraction of a cent,
which is an order of magnitude below the transcript providers it precedes.
"""

import base64
import logging
import shutil
import subprocess
import tempfile
from decimal import Decimal
from pathlib import Path
from typing import Any, Protocol
from uuid import UUID

import httpx

from ladle.acquisition.errors import (
    AcquisitionError,
    MalformedProviderResponse,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
    ProviderUnavailable,
    TranscriptUnavailable,
)
from ladle.acquisition.free.ytdlp import YtDlpClient
from ladle.acquisition.models import (
    SourceVideoDescriptor,
    TextEvidence,
    TranscriptResult,
)
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink

LOGGER = logging.getLogger(__name__)

_SAMPLE_RATE = "16000"
_BITRATE = "32k"
_MAX_SEGMENT_CHARACTERS = 20_000

# Whisper returns chunk-level segments — often the whole clip as one entry —
# which is too coarse to tell the model which moment a step came from. Word
# timings are fine enough to rebuild utterances, so we regroup them here.
# A break needs a real pause or a sentence ending; the caps stop a creator
# who never pauses from producing one segment for the entire video.
_WORD_PAUSE_SECONDS = 0.55
_MIN_SEGMENT_SECONDS = 2.0
_MAX_SEGMENT_SECONDS = 14.0
_MAX_SEGMENT_TEXT = 240
# Fullwidth stops are deliberate: CJK transcripts end sentences with them.
_SENTENCE_ENDINGS = (".", "!", "?", "。", "！", "？")  # noqa: RUF001


class AudioSource(Protocol):
    def audio(
        self,
        source: SourceVideoDescriptor,
        *,
        media_url: str | None,
        work_dir: Path,
    ) -> Path | None: ...


class MediaAudioSource:
    """Fetches a compact audio file for a source, or None when it cannot.

    Instagram hands us a direct media URL through its embed payload; every
    other platform goes through yt-dlp.
    """

    def __init__(
        self,
        *,
        ytdlp: YtDlpClient,
        http: httpx.Client,
        ffmpeg_path: str | None = None,
        max_media_bytes: int = 120 * 1024 * 1024,
        download_timeout_seconds: float = 120,
        convert_timeout_seconds: float = 180,
    ) -> None:
        self._ytdlp = ytdlp
        self._http = http
        self._ffmpeg = ffmpeg_path or shutil.which("ffmpeg")
        self._max_media_bytes = max_media_bytes
        self._download_timeout = download_timeout_seconds
        self._convert_timeout = convert_timeout_seconds

    @property
    def available(self) -> bool:
        return self._ffmpeg is not None

    def audio(
        self,
        source: SourceVideoDescriptor,
        *,
        media_url: str | None,
        work_dir: Path,
    ) -> Path | None:
        if self._ffmpeg is None:
            return None
        if media_url:
            downloaded = self._download(media_url, work_dir)
            if downloaded is not None:
                return self._to_mp3(downloaded, work_dir)
        extracted = self._ytdlp_audio(source.canonical_url, work_dir)
        if extracted is None:
            return None
        return self._to_mp3(extracted, work_dir)

    def _download(self, url: str, work_dir: Path) -> Path | None:
        target = work_dir / "source-media"
        try:
            with self._http.stream(
                "GET", url, timeout=self._download_timeout, follow_redirects=True
            ) as response:
                response.raise_for_status()
                written = 0
                with target.open("wb") as handle:
                    for chunk in response.iter_bytes():
                        written += len(chunk)
                        if written > self._max_media_bytes:
                            LOGGER.info("Media exceeded the size cap; abandoning")
                            return None
                        handle.write(chunk)
        except httpx.HTTPError as error:
            LOGGER.info("Media download failed: %s", error)
            return None
        return target if target.stat().st_size > 0 else None

    def _ytdlp_audio(self, url: str, work_dir: Path) -> Path | None:
        if not self._ytdlp.available:
            return None
        downloaded = self._ytdlp.audio(url, work_dir=work_dir)
        return downloaded

    def _to_mp3(self, media: Path, work_dir: Path) -> Path | None:
        assert self._ffmpeg is not None
        target = work_dir / "audio.mp3"
        command = [
            self._ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(media),
            "-vn",
            "-ac",
            "1",
            "-ar",
            _SAMPLE_RATE,
            "-b:a",
            _BITRATE,
            "-c:a",
            "libmp3lame",
            str(target),
        ]
        try:
            result = subprocess.run(
                command,
                text=True,
                capture_output=True,
                timeout=self._convert_timeout,
                check=False,
            )
        except (subprocess.TimeoutExpired, OSError) as error:
            LOGGER.info("Audio conversion failed: %s", error)
            return None
        if result.returncode != 0 or not target.exists():
            LOGGER.info("ffmpeg could not extract audio: %s", result.stderr[-300:])
            return None
        return target if target.stat().st_size > 0 else None


class WhisperTranscriber:
    """Whisper over an OpenAI-compatible endpoint.

    Defaults to OpenRouter so the key already in the environment is reused
    rather than adding another secret to a file that is a single point of
    failure. Any compatible host works by pointing the base URL elsewhere.
    """

    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: str,
        base_url: str,
        model_id: str,
        max_audio_bytes: int = 20 * 1024 * 1024,
        usage: ProviderUsageSink | None = None,
    ) -> None:
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._model_id = model_id
        self._max_audio_bytes = max_audio_bytes
        self._usage = usage or NullProviderUsageSink()

    def transcribe(
        self,
        audio: Path,
        *,
        job_id: UUID,
        source_revision: str,
    ) -> TranscriptResult:
        idempotency_key = f"whisper:transcript:{source_revision}"
        self._usage.started(
            job_id=job_id,
            provider="whisper",
            operation="transcript",
            idempotency_key=idempotency_key,
            external_job_id=None,
            billed_units=Decimal(0),
        )
        try:
            result = self._transcribe(audio)
        except AcquisitionError as error:
            self._usage.failed(
                job_id=job_id,
                idempotency_key=idempotency_key,
                failure_code=type(error).__name__,
            )
            raise
        self._usage.completed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            billed_units=result.billed_units,
            latency_ms=None,
        )
        return result

    def _transcribe(self, audio: Path) -> TranscriptResult:
        raw = audio.read_bytes()
        if not raw:
            raise TranscriptUnavailable("audio file was empty")
        if len(raw) > self._max_audio_bytes:
            raise TranscriptUnavailable(
                f"audio is {len(raw)} bytes, above the {self._max_audio_bytes} cap"
            )
        payload = {
            "model": self._model_id,
            "input_audio": {
                "data": base64.b64encode(raw).decode("ascii"),
                "format": audio.suffix.lstrip(".").lower() or "mp3",
            },
            "response_format": "verbose_json",
            # Word timings are what make per-step timestamps meaningful; the
            # segment list alone comes back in 30-second chunks. Hosts that
            # ignore this still return segments, which _transcript falls back to.
            "timestamp_granularities": ["word", "segment"],
            "temperature": 0,
        }
        try:
            response = self._http.post(
                f"{self._base_url}/audio/transcriptions",
                json=payload,
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "Content-Type": "application/json",
                    "X-Title": "Ladle",
                },
            )
        except httpx.TimeoutException as error:
            raise ProviderTransientError("transcription timed out") from error
        except httpx.HTTPError as error:
            raise ProviderUnavailable(f"transcription failed: {error}") from error
        self._raise_for_status(response)
        try:
            body = response.json()
        except ValueError as error:
            raise MalformedProviderResponse(
                "transcription returned non-JSON"
            ) from error
        if not isinstance(body, dict):
            raise MalformedProviderResponse(
                "transcription returned an unexpected shape"
            )
        return _transcript(body, model_id=self._model_id)

    def _raise_for_status(self, response: httpx.Response) -> None:
        if response.status_code < 400:
            return
        detail = response.text[:400]
        if response.status_code in (401, 403):
            raise ProviderAuthenticationError(f"transcription auth failed: {detail}")
        if response.status_code == 429:
            raise ProviderQuotaError(f"transcription quota exhausted: {detail}")
        if response.status_code >= 500:
            raise ProviderTransientError(f"transcription unavailable: {detail}")
        raise ProviderUnavailable(f"transcription rejected the request: {detail}")


def _words(body: dict[str, Any]) -> list[tuple[str, float, float]]:
    """Word timings, keeping only entries that carry a usable window."""

    collected: list[tuple[str, float, float]] = []
    for entry in body.get("words") or []:
        if not isinstance(entry, dict):
            continue
        text = str(entry.get("word") or entry.get("text") or "").strip()
        start = _seconds(entry.get("start"))
        end = _seconds(entry.get("end"))
        if not text or start is None or end is None or end < start:
            continue
        collected.append((text, start, end))
    return collected


def _segments_from_words(
    words: list[tuple[str, float, float]],
    *,
    provenance: str,
) -> list[TextEvidence]:
    """Regroup word timings into utterance-sized, individually timed evidence."""

    segments: list[TextEvidence] = []
    pending: list[str] = []
    start = 0.0
    end = 0.0

    def flush() -> None:
        nonlocal pending
        if not pending:
            return
        segments.append(
            TextEvidence(
                text=" ".join(pending)[:_MAX_SEGMENT_CHARACTERS],
                start_seconds=start,
                end_seconds=end,
                provenance=provenance,
                generated=True,
            )
        )
        pending = []

    for index, (text, word_start, word_end) in enumerate(words):
        if not pending:
            start = word_start
        pending.append(text)
        end = word_end
        duration = end - start
        gap = words[index + 1][1] - word_end if index + 1 < len(words) else None
        long_enough = duration >= _MIN_SEGMENT_SECONDS
        ends_sentence = text.endswith(_SENTENCE_ENDINGS)
        paused = gap is not None and gap >= _WORD_PAUSE_SECONDS
        if (
            (long_enough and (ends_sentence or paused))
            or duration >= _MAX_SEGMENT_SECONDS
            or sum(len(value) + 1 for value in pending) >= _MAX_SEGMENT_TEXT
        ):
            flush()
    flush()
    return segments


def _transcript(body: dict[str, Any], *, model_id: str) -> TranscriptResult:
    provenance = f"whisper:{model_id}"
    words = _words(body)
    if words:
        from_words = _segments_from_words(words, provenance=provenance)
        if from_words:
            return TranscriptResult(
                segments=from_words,
                language=str(body.get("language") or "") or None,
                billed_units=Decimal(1),
            )
    segments: list[TextEvidence] = []
    for entry in body.get("segments") or []:
        if not isinstance(entry, dict):
            continue
        text = str(entry.get("text") or "").strip()
        if not text:
            continue
        segments.append(
            TextEvidence(
                text=text[:_MAX_SEGMENT_CHARACTERS],
                start_seconds=_seconds(entry.get("start")),
                end_seconds=_seconds(entry.get("end")),
                provenance=provenance,
                generated=True,
            )
        )
    if not segments:
        # Some hosts return only a flat transcript; keep it, but without
        # inventing a time window it never gave us.
        text = str(body.get("text") or "").strip()
        if not text:
            raise TranscriptUnavailable("transcription produced no text")
        segments.append(
            TextEvidence(
                text=text[:_MAX_SEGMENT_CHARACTERS],
                start_seconds=None,
                end_seconds=None,
                provenance=provenance,
                generated=True,
            )
        )
    return TranscriptResult(
        segments=segments,
        language=str(body.get("language") or "") or None,
        # One unit per call. The daily limit counts provider calls, not
        # seconds of audio or tokens.
        billed_units=Decimal(1),
    )


def _seconds(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    return float(value) if value >= 0 else None


class AudioTranscriptProvider:
    """Fetch the audio, transcribe it, hand back timed evidence."""

    def __init__(
        self,
        *,
        audio_source: AudioSource,
        transcriber: WhisperTranscriber,
        max_duration_seconds: float = 1800,
    ) -> None:
        self._audio_source = audio_source
        self._transcriber = transcriber
        self._max_duration_seconds = max_duration_seconds

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        media_url: str | None = None,
        duration_seconds: float | None = None,
    ) -> TranscriptResult:
        if (
            duration_seconds is not None
            and duration_seconds > self._max_duration_seconds
        ):
            raise TranscriptUnavailable(
                f"video is {duration_seconds:.0f}s, above the transcription cap"
            )
        with tempfile.TemporaryDirectory(prefix="ladle-audio-") as folder:
            work_dir = Path(folder)
            audio = self._audio_source.audio(
                source,
                media_url=media_url,
                work_dir=work_dir,
            )
            if audio is None:
                raise TranscriptUnavailable("audio could not be acquired")
            return self._transcriber.transcribe(
                audio,
                job_id=job_id,
                source_revision=source.source_revision,
            )
