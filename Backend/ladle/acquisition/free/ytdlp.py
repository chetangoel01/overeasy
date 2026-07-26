"""Keyless metadata and subtitle acquisition via yt-dlp.

This is the first rung of the acquisition ladder: everything here costs nothing
but process time, so it runs before any billed provider is touched.
"""

import html
import json
import logging
import math
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

import httpx

from ladle.acquisition.errors import (
    MalformedProviderResponse,
    PrivateOrDeleted,
    ProviderTransientError,
    ProviderUnavailable,
)
from ladle.acquisition.models import MediaMetadata, TextEvidence
from ladle.infrastructure.dns import (
    DNSResolver,
    PinnedHTTPClient,
    SystemDNSResolver,
    UnsafeNetworkTarget,
)

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
_MAX_SUBTITLE_BYTES = 4 * 1024 * 1024


@dataclass(frozen=True)
class SubtitleTrack:
    language: str
    generated: bool
    url: str | None = None


@dataclass
class YtDlpMedia:
    metadata: MediaMetadata
    canonical_url: str | None = None
    media_url: str | None = None
    audio_url: str | None = None
    video_url: str | None = None
    manual_languages: list[str] = field(default_factory=list)
    generated_languages: list[str] = field(default_factory=list)
    manual_subtitle_urls: dict[str, str] = field(default_factory=dict)
    generated_subtitle_urls: dict[str, str] = field(default_factory=dict)

    def preferred_track(self) -> SubtitleTrack | None:
        """Creator-authored captions beat machine captions; English beats nothing."""
        for language in _PREFERRED_LANGUAGES:
            if language in self.manual_languages:
                return SubtitleTrack(
                    language=language,
                    generated=False,
                    url=self.manual_subtitle_urls.get(language),
                )
        for language in _PREFERRED_LANGUAGES:
            if language in self.generated_languages:
                return SubtitleTrack(
                    language=language,
                    generated=True,
                    url=self.generated_subtitle_urls.get(language),
                )
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
        cookies_file: str | Path | None = None,
        runner: CommandRunner = run_command,
        http: httpx.Client | None = None,
        dns: DNSResolver | None = None,
        metadata_timeout_seconds: float = 90,
        subtitle_timeout_seconds: float = 90,
    ) -> None:
        self._binary = binary or _discover_binary()
        self._cookies_file = str(cookies_file) if cookies_file is not None else None
        self._runner = runner
        self._metadata_timeout = metadata_timeout_seconds
        self._http = PinnedHTTPClient(
            dns=dns or SystemDNSResolver(),
            client=http
            or httpx.Client(
                timeout=subtitle_timeout_seconds,
                trust_env=False,
            ),
        )

    @property
    def available(self) -> bool:
        return self._binary is not None

    def metadata(self, url: str) -> YtDlpMedia:
        payload = self._json(
            self._command(
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
            ),
            timeout=self._metadata_timeout,
        )
        return _media_from_payload(payload)

    def subtitles(self, url: str, *, track: SubtitleTrack) -> list[TextEvidence]:
        """Fetch the provider-returned VTT through the pinned HTTP client.

        yt-dlp only discovers metadata. It never receives authority to follow a
        provider-returned caption URL itself.
        """
        del url
        if track.url is None:
            return []
        try:
            response = self._http.get(track.url, max_bytes=_MAX_SUBTITLE_BYTES)
            response.raise_for_status()
            raw = response.text
        except (httpx.HTTPError, UnsafeNetworkTarget) as error:
            LOGGER.info("subtitle download failed: %s", error)
            return []
        return parse_vtt(raw, generated=track.generated, language=track.language)

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

    def _command(self, *arguments: str) -> list[str]:
        # Ignore user/system configuration and proxy environment variables.
        # Infrastructure egress policy remains the backstop for requests the
        # extractor makes to allowlisted social platforms.
        command = [self._require_binary(), "--no-config", "--proxy", ""]
        if self._cookies_file is not None:
            command.extend(("--cookies", self._cookies_file))
        command.extend(arguments)
        return command


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
        media_url=_media_url(payload),
        audio_url=_audio_url(payload),
        video_url=_video_url(payload),
        manual_languages=_languages(payload.get("subtitles")),
        generated_languages=_languages(payload.get("automatic_captions")),
        manual_subtitle_urls=_subtitle_urls(payload.get("subtitles")),
        generated_subtitle_urls=_subtitle_urls(payload.get("automatic_captions")),
    )


def _languages(value: Any) -> list[str]:
    if not isinstance(value, dict):
        return []
    return [str(key) for key in value]


def _subtitle_urls(value: Any) -> dict[str, str]:
    if not isinstance(value, dict):
        return {}
    result: dict[str, str] = {}
    for language, candidates in value.items():
        if not isinstance(candidates, list):
            continue
        preferred = next(
            (
                candidate
                for candidate in candidates
                if isinstance(candidate, dict)
                and candidate.get("ext") == "vtt"
                and isinstance(candidate.get("url"), str)
            ),
            None,
        )
        if preferred is not None:
            result[str(language)] = str(preferred["url"])
    return result


def _media_url(payload: dict[str, Any]) -> str | None:
    formats = _formats(payload)
    candidates = [
        value
        for value in formats
        if _https_url(value) is not None
        and value.get("vcodec") not in (None, "none")
        and value.get("acodec") not in (None, "none")
    ]
    if not candidates:
        return None
    return _https_url(_best_video(candidates))


def _audio_url(payload: dict[str, Any]) -> str | None:
    candidates = [
        value
        for value in _formats(payload)
        if _https_url(value) is not None and value.get("acodec") not in (None, "none")
    ]
    if not candidates:
        return None
    audio_only = [
        value for value in candidates if value.get("vcodec") in (None, "none")
    ]
    selected = max(
        audio_only or candidates,
        key=lambda value: _metric(value.get("abr") or value.get("tbr")),
    )
    return _https_url(selected)


def _video_url(payload: dict[str, Any]) -> str | None:
    candidates = [
        value
        for value in _formats(payload)
        if _https_url(value) is not None and value.get("vcodec") not in (None, "none")
    ]
    if not candidates:
        return None
    video_only = [
        value for value in candidates if value.get("acodec") in (None, "none")
    ]
    return _https_url(_best_video(video_only or candidates))


def _formats(payload: dict[str, Any]) -> list[dict[str, Any]]:
    value = payload.get("formats")
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def _https_url(value: dict[str, Any]) -> str | None:
    url = value.get("url")
    return str(url) if isinstance(url, str) and url.startswith("https://") else None


def _best_video(candidates: list[dict[str, Any]]) -> dict[str, Any]:
    bounded = [value for value in candidates if 0 < _metric(value.get("height")) <= 720]
    if bounded:
        return max(bounded, key=lambda value: _metric(value.get("height")))
    measured = [value for value in candidates if _metric(value.get("height")) > 0]
    return (
        min(measured, key=lambda value: _metric(value.get("height")))
        if measured
        else candidates[0]
    )


def _metric(value: Any) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return 0
    number = float(value)
    return number if math.isfinite(number) and number >= 0 else 0


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
