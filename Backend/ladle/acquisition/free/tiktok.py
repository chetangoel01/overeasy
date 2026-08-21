"""TikTok's own speech recognition, which it publishes for free.

yt-dlp reports no subtitles for TikTok, but the video page embeds a JSON blob
containing `subtitleInfos` — WebVTT tracks TikTok generated with Whisper and
serves from its CDN. Sampled across eight real cooking videos, six had one.
That is the difference between a paid transcript and no transcript at all for
the platform most of the library comes from.

The same blob carries `stickersOnItem`, the on-screen text overlays creators
use for dish names and ingredient lists.
"""

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any

import httpx

from ladle.acquisition.free.links import LinkFetcher, UnsafeURL
from ladle.acquisition.free.ytdlp import parse_vtt
from ladle.acquisition.models import MediaMetadata, TextEvidence, VisualEvidence

LOGGER = logging.getLogger(__name__)

_BLOB = re.compile(
    r'<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>',
    re.S,
)
_ENGLISH = "eng"
_MAX_STICKERS = 8


@dataclass
class TikTokPageEvidence:
    metadata: MediaMetadata | None = None
    transcript: list[TextEvidence] = field(default_factory=list)
    stickers: list[VisualEvidence] = field(default_factory=list)
    language: str | None = None
    title: str | None = None

    @property
    def is_empty(self) -> bool:
        return self.metadata is None and not self.transcript and not self.stickers


class TikTokPageClient:
    def __init__(self, *, fetcher: LinkFetcher) -> None:
        self._fetcher = fetcher

    def evidence(self, canonical_url: str) -> TikTokPageEvidence:
        """Best-effort. Any failure means the paid chain simply runs as before."""
        evidence = TikTokPageEvidence()
        try:
            page = self._fetcher.fetch_raw(canonical_url)
        except (UnsafeURL, OSError, httpx.HTTPError) as error:
            LOGGER.info("TikTok page unavailable for %s: %s", canonical_url, error)
            return evidence
        item = _item_struct(page)
        if item is None:
            LOGGER.info("TikTok page carried no rehydration data: %s", canonical_url)
            return evidence

        evidence.title = _sticker_title(item)
        evidence.metadata = _metadata(item, title=evidence.title)
        evidence.stickers = _stickers(item)
        track = _english_track(item)
        if track is None:
            return evidence
        try:
            raw = self._fetcher.fetch_raw(str(track["Url"]))
        except (UnsafeURL, OSError, httpx.HTTPError) as error:
            LOGGER.info("TikTok caption track unavailable: %s", error)
            return evidence
        if "WEBVTT" not in raw[:200]:
            return evidence
        language = str(track.get("LanguageCodeName") or "eng-US")
        # TikTok's tracks are machine-generated, and the recipe contract cares:
        # `generated` is what tells the extractor this is ASR, not the creator.
        evidence.transcript = parse_vtt(
            raw,
            generated=True,
            language=language,
            source="tiktok:asr",
        )
        if evidence.transcript:
            evidence.language = language
        return evidence


def _metadata(item: dict[str, Any], *, title: str | None) -> MediaMetadata | None:
    description = str(item.get("desc") or "").strip()
    author = item.get("author")
    creator = (
        str(author.get("nickname") or author.get("uniqueId") or "").strip()
        if isinstance(author, dict)
        else ""
    )
    video = item.get("video")
    thumbnail = ""
    duration: float | None = None
    if isinstance(video, dict):
        candidate = str(video.get("cover") or video.get("originCover") or "").strip()
        thumbnail = candidate if candidate.startswith("https://") else ""
        value = video.get("duration")
        if (
            isinstance(value, int | float)
            and not isinstance(value, bool)
            and value >= 0
        ):
            duration = float(value)
    if not any((title, description, creator, thumbnail, duration is not None)):
        return None
    return MediaMetadata(
        title=title,
        description=description[:50_000],
        creator_name=creator or None,
        thumbnail_url=thumbnail or None,
        duration_seconds=duration,
    )


def _item_struct(page: str) -> dict[str, Any] | None:
    match = _BLOB.search(page)
    if match is None:
        return None
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError:
        return None
    scope = payload.get("__DEFAULT_SCOPE__")
    if not isinstance(scope, dict):
        return None
    detail = scope.get("webapp.video-detail")
    if not isinstance(detail, dict):
        return None
    info = detail.get("itemInfo")
    if not isinstance(info, dict):
        return None
    item = info.get("itemStruct")
    return item if isinstance(item, dict) else None


def _english_track(item: dict[str, Any]) -> dict[str, Any] | None:
    video = item.get("video")
    if not isinstance(video, dict):
        return None
    infos = video.get("subtitleInfos")
    if not isinstance(infos, list):
        return None
    for info in infos:
        if not isinstance(info, dict) or not info.get("Url"):
            continue
        if str(info.get("Format", "")).casefold() != "webvtt":
            continue
        if str(info.get("LanguageCodeName", "")).casefold().startswith(_ENGLISH):
            return info
    return None


def _sticker_values(item: dict[str, Any]) -> list[str]:
    stickers = item.get("stickersOnItem")
    if not isinstance(stickers, list):
        return []
    values: list[str] = []
    for sticker in stickers:
        if not isinstance(sticker, dict):
            continue
        texts = sticker.get("stickerText")
        if not isinstance(texts, list):
            continue
        for text in texts:
            cleaned = re.sub(r"\s+", " ", str(text or "")).strip()
            if cleaned:
                values.append(cleaned)
    return values[:_MAX_STICKERS]


def _stickers(item: dict[str, Any]) -> list[VisualEvidence]:
    return [
        VisualEvidence(
            text=value[:20_000],
            timestamp_seconds=None,
            provenance="tiktok:sticker",
        )
        for value in _sticker_values(item)
    ]


def _sticker_title(item: dict[str, Any]) -> str | None:
    """A creator's on-screen title beats the caption's opening hook.

    TikTok titles start with promo copy — "This might be your new obsession…" —
    while the sticker says "Feta and Spinach Rice Paper Rolls".
    """
    for value in _sticker_values(item):
        first = value.splitlines()[0].strip()
        if 3 <= len(first) <= 120:
            return first
    return None
