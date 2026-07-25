"""Keyless metadata and subtitle acquisition via yt-dlp.

This is the first rung of the acquisition ladder: everything here costs nothing
but process time, so it runs before any billed provider is touched.
"""

import html
import json
import logging
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from ladle.acquisition.errors import (
    MalformedProviderResponse,
    PrivateOrDeleted,
    ProviderTransientError,
    ProviderUnavailable,
)
from ladle.acquisition.models import MediaMetadata, TextEvidence

LOGGER = logging.getLogger(__name__)

_PRIVATE_MARKERS = (
    "video unavailable",
    "this video is private",
    "this post may not be available",
    "content isn't available",
    "content is not available",
    "account has been banned",
    "video has been removed",
    "removed for violating",
    "requested content is not available",
    "page not found",
    "http error 404",
    "http error 410",
)
_TRANSIENT_MARKERS = (
    "timed out",
    "temporary failure",
    "connection reset",
    "http error 429",
    "http error 500",
    "http error 502",
    "http error 503",
    "unable to download webpage",
)
# yt-dlp reports login walls and datacenter-IP blocks the same way; both mean the
# free rung cannot see this video, not that the video is gone.
_BLOCKED_MARKERS = (
    "sign in to confirm",
    "login required",
    "requires authentication",
    "use --cookies",
    "cookies-from-browser",
    "confirm your age",
)

_PREFERRED_LANGUAGES = ("en", "en-US", "en-GB", "en-orig")
_CUE_TIME = re.compile(
    r"(\d{2,}):(\d{2}):(\d{2})[.,](\d{1,3})\s*-->\s*"
    r"(\d{2,}):(\d{2}):(\d{2})[.,](\d{1,3})"
)
_TAG = re.compile(r"<[^>]+>")
_WHITESPACE = re.compile(r"\s+")

# Cues arrive a few words at a time; grouping them keeps timestamps useful for
# step attribution without spending a prompt segment on every three words.
_SEGMENT_CHARACTER_TARGET = 400
_MAX_SEGMENTS = 400


@dataclass(frozen=True)
class SubtitleTrack:
    language: str
    generated: bool


@dataclass
class YtDlpMedia:
    metadata: MediaMetadata
    canonical_url: str | None = None
    manual_languages: list[str] = field(default_factory=list)
    generated_languages: list[str] = field(default_factory=list)

    def preferred_track(self) -> SubtitleTrack | None:
        """Creator-authored captions beat machine captions; English beats nothing."""
        for language in _PREFERRED_LANGUAGES:
            if language in self.manual_languages:
                return SubtitleTrack(language=language, generated=False)
        for language in _PREFERRED_LANGUAGES:
            if language in self.generated_languages:
                return SubtitleTrack(language=language, generated=True)
        return None


class CommandRunner(Protocol):
    def __call__(
        self, command: list[str], *, timeout: float
    ) -> subprocess.CompletedProcess[str]: ...


def _discover_binary() -> str | None:
    """yt-dlp installs beside the interpreter, which is not always on PATH."""
    sibling = Path(sys.executable).parent / "yt-dlp"
    if sibling.is_file():
        return str(sibling)
    return shutil.which("yt-dlp")


def run_command(
    command: list[str], *, timeout: float
) -> subprocess.CompletedProcess[str]:
    # argv is assembled here and never shell-parsed.
    return subprocess.run(
        command,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


class YtDlpClient:
    def __init__(
        self,
        *,
        binary: str | None = None,
        runner: CommandRunner = run_command,
        metadata_timeout_seconds: float = 90,
        subtitle_timeout_seconds: float = 90,
        audio_timeout_seconds: float = 240,
    ) -> None:
        self._binary = binary or _discover_binary()
        self._runner = runner
        self._metadata_timeout = metadata_timeout_seconds
        self._subtitle_timeout = subtitle_timeout_seconds
        self._audio_timeout = audio_timeout_seconds

    @property
    def available(self) -> bool:
        return self._binary is not None

    def metadata(self, url: str) -> YtDlpMedia:
        payload = self._json(
            [
                self._require_binary(),
                "--no-playlist",
                "--skip-download",
                "--dump-single-json",
                "--no-warnings",
                "--socket-timeout",
                "20",
                "--retries",
                "2",
                "--extractor-retries",
                "2",
                url,
            ],
            timeout=self._metadata_timeout,
        )
        return _media_from_payload(payload)

    def subtitles(self, url: str, *, track: SubtitleTrack) -> list[TextEvidence]:
        """Timed caption cues, or an empty list when the track will not download.

        A missing subtitle file is an ordinary outcome, not a provider failure —
        the caller simply falls through to the next rung.
        """
        with tempfile.TemporaryDirectory(prefix="ladle-free-") as folder:
            work_dir = Path(folder)
            command = [
                self._require_binary(),
                "--no-playlist",
                "--skip-download",
                "--write-auto-subs" if track.generated else "--write-subs",
                "--sub-langs",
                track.language,
                "--sub-format",
                "vtt",
                "--no-warnings",
                "--socket-timeout",
                "20",
                "-o",
                str(work_dir / "source.%(ext)s"),
                url,
            ]
            try:
                result = self._runner(command, timeout=self._subtitle_timeout)
            except subprocess.TimeoutExpired:
                LOGGER.info("yt-dlp subtitle download timed out for %s", url)
                return []
            if result.returncode != 0:
                LOGGER.info(
                    "yt-dlp subtitle download failed: %s",
                    _tail(result.stderr or result.stdout),
                )
                return []
            files = sorted(
                work_dir.glob("source*.vtt"),
                key=lambda item: item.stat().st_size,
                reverse=True,
            )
            if not files:
                return []
            raw = files[0].read_text(errors="replace")
        return parse_vtt(raw, generated=track.generated, language=track.language)

    def audio(self, url: str, *, work_dir: Path) -> Path | None:
        """Best available audio stream, or None when it will not download."""
        return self._download(url, work_dir=work_dir, selector="bestaudio/best")

    def video(self, url: str, *, work_dir: Path) -> Path | None:
        """A file that carries pictures, which "bestaudio" often does not.

        Instagram publishes a separate audio stream, so the audio selector
        returns a bare .m4a — everything transcription needs and nothing a
        frame can be cut from. TikTok has no separate stream, which is why
        sampling frames appeared to work there and nowhere else.
        """

        return self._download(
            url,
            work_dir=work_dir,
            selector="best[vcodec!=none]/bestvideo*+bestaudio/best",
        )

    def _download(self, url: str, *, work_dir: Path, selector: str) -> Path | None:
        command = [
            self._require_binary(),
            "--no-playlist",
            "-f",
            selector,
            "--no-warnings",
            "--socket-timeout",
            "20",
            "--max-filesize",
            "150M",
            "-o",
            str(work_dir / "download.%(ext)s"),
            url,
        ]
        try:
            result = self._runner(command, timeout=self._audio_timeout)
        except (subprocess.TimeoutExpired, OSError) as error:
            LOGGER.info("yt-dlp download failed for %s: %s", url, error)
            return None
        if result.returncode != 0:
            LOGGER.info(
                "yt-dlp download failed: %s",
                _tail(result.stderr or result.stdout),
            )
            return None
        files = sorted(
            (item for item in work_dir.glob("download.*") if item.is_file()),
            key=lambda item: item.stat().st_size,
            reverse=True,
        )
        return files[0] if files else None

    def _json(self, command: list[str], *, timeout: float) -> dict[str, Any]:
        try:
            result = self._runner(command, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            raise ProviderTransientError("yt-dlp timed out") from error
        except OSError as error:
            raise ProviderUnavailable(f"yt-dlp could not run: {error}") from error
        if result.returncode != 0:
            raise _classify(result.stderr or result.stdout)
        try:
            payload = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise MalformedProviderResponse("yt-dlp returned non-JSON") from error
        if not isinstance(payload, dict):
            raise MalformedProviderResponse("yt-dlp returned an unexpected shape")
        return payload

    def _require_binary(self) -> str:
        if self._binary is None:
            raise ProviderUnavailable("yt-dlp is not installed")
        return self._binary


def _classify(stderr: str) -> ProviderUnavailable | PrivateOrDeleted:
    detail = _tail(stderr)
    haystack = detail.casefold()
    if any(marker in haystack for marker in _BLOCKED_MARKERS):
        return ProviderUnavailable(f"yt-dlp was blocked: {detail}")
    if any(marker in haystack for marker in _PRIVATE_MARKERS):
        return PrivateOrDeleted(detail)
    if any(marker in haystack for marker in _TRANSIENT_MARKERS):
        return ProviderTransientError(detail)
    return ProviderUnavailable(detail)


def _tail(value: str | None, limit: int = 400) -> str:
    text = _WHITESPACE.sub(" ", str(value or "")).strip()
    return text[-limit:] or "yt-dlp failed without detail"


def _media_from_payload(payload: dict[str, Any]) -> YtDlpMedia:
    title = _text(payload.get("title") or payload.get("fulltitle"))
    description = _text(payload.get("description"))
    creator = _text(
        payload.get("uploader") or payload.get("channel") or payload.get("creator")
    )
    canonical = _text(payload.get("webpage_url") or payload.get("original_url"))
    duration = payload.get("duration")
    return YtDlpMedia(
        metadata=MediaMetadata(
            title=title or None,
            description=description[:50_000],
            creator_name=creator or None,
            thumbnail_url=_text(payload.get("thumbnail")) or None,
            duration_seconds=float(duration)
            if isinstance(duration, int | float) and duration >= 0
            else None,
        ),
        canonical_url=canonical or None,
        manual_languages=_languages(payload.get("subtitles")),
        generated_languages=_languages(payload.get("automatic_captions")),
    )


def _languages(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return []
    return [str(key) for key in value]


def _text(value: Any) -> str:
    return str(value or "").strip()


def parse_vtt(
    raw: str,
    *,
    generated: bool,
    language: str,
    source: str = "ytdlp",
) -> list[TextEvidence]:
    """WebVTT cues with their timestamps preserved.

    RecipeBox flattens captions into one untimed string. Ladle needs the timing:
    a step's sourceStartSeconds is only meaningful if the evidence kept its cue
    window.
    """
    cues = _cues(raw)
    if not cues:
        return []
    provenance = f"{source}:{'auto' if generated else 'manual'}:{language}"
    segments: list[TextEvidence] = []
    buffer: list[str] = []
    start = 0.0
    end = 0.0
    for cue_start, cue_end, text in cues:
        if not buffer:
            start = cue_start
        buffer.append(text)
        end = cue_end
        if sum(len(item) + 1 for item in buffer) >= _SEGMENT_CHARACTER_TARGET:
            segments.append(
                _evidence(buffer, start, end, provenance, generated=generated)
            )
            buffer = []
        if len(segments) >= _MAX_SEGMENTS:
            return segments
    if buffer:
        segments.append(_evidence(buffer, start, end, provenance, generated=generated))
    return segments


def _evidence(
    parts: list[str],
    start: float,
    end: float,
    provenance: str,
    *,
    generated: bool,
) -> TextEvidence:
    return TextEvidence(
        text=" ".join(parts)[:20_000],
        start_seconds=start,
        end_seconds=max(end, start),
        provenance=provenance,
        generated=generated,
    )


def _cues(raw: str) -> list[tuple[float, float, str]]:
    cues: list[tuple[float, float, str]] = []
    previous = ""
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    index = 0
    while index < len(lines):
        match = _CUE_TIME.search(lines[index])
        if match is None:
            index += 1
            continue
        start = _seconds(match.group(1), match.group(2), match.group(3), match.group(4))
        end = _seconds(match.group(5), match.group(6), match.group(7), match.group(8))
        index += 1
        payload: list[str] = []
        while index < len(lines) and lines[index].strip():
            if _CUE_TIME.search(lines[index]):
                break
            payload.append(lines[index])
            index += 1
        text = _clean_cue(" ".join(payload))
        if not text or text == previous:
            continue
        # YouTube's rolling captions repeat the previous cue as a prefix.
        if previous and text.startswith(previous) and len(text) > len(previous):
            trimmed = text[len(previous) :].strip()
            if trimmed:
                cues.append((start, end, trimmed))
                previous = text
            continue
        cues.append((start, end, text))
        previous = text
    return cues


def _clean_cue(value: str) -> str:
    text = html.unescape(_TAG.sub("", value))
    return _WHITESPACE.sub(" ", text).strip()


def _seconds(hours: str, minutes: str, secs: str, fraction: str) -> float:
    total = int(hours) * 3600 + int(minutes) * 60 + int(secs)
    return total + int(fraction.ljust(3, "0")) / 1000
