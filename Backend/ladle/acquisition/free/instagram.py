"""Instagram captions, without an account.

yt-dlp cannot read Instagram without browser cookies, which do not exist in a
container — so the platform was entirely dark. But Instagram still has to serve
posts to third-party sites that embed them, and that path has no login wall:
`/embed/captioned/` returns the full caption, the owner handle, the duration
and a thumbnail inside a `contextJSON` blob.

Captions are where Instagram recipes live, so this is usually the whole recipe
rather than a hint at one.
"""

import json
import logging
import re
from dataclasses import dataclass

import httpx

from ladle.acquisition.free.links import LinkFetcher, UnsafeURL
from ladle.acquisition.models import (
    MediaMetadata,
    SourceCounts,
    SourceVideoDescriptor,
    VisualEvidence,
)

LOGGER = logging.getLogger(__name__)

_SHORTCODE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_CONTEXT_KEY = '"contextJSON":'
_MAX_TITLE_CHARACTERS = 120


@dataclass
class InstagramMedia:
    metadata: MediaMetadata
    observations: list[VisualEvidence]
    # Instagram publishes no transcript, so the media file is the only route to
    # what was actually said. It downloads without authentication.
    media_url: str | None = None


class InstagramEmbedClient:
    def __init__(self, *, fetcher: LinkFetcher) -> None:
        self._fetcher = fetcher

    def metadata(self, source: SourceVideoDescriptor) -> InstagramMedia | None:
        """Best-effort. None means the paid chain runs exactly as it did before."""
        shortcode = source.platform_video_id
        if _SHORTCODE.fullmatch(shortcode) is None:
            return None
        url = f"https://www.instagram.com/reel/{shortcode}/embed/captioned/"
        try:
            page = self._fetcher.fetch_raw(url)
        except (UnsafeURL, OSError, httpx.HTTPError) as error:
            LOGGER.info("Instagram embed unavailable for %s: %s", shortcode, error)
            return None
        media = _shortcode_media(page)
        if media is None:
            LOGGER.info("Instagram embed carried no post data: %s", shortcode)
            return None
        return _media(media)


def _shortcode_media(page: str) -> dict[str, object] | None:
    index = page.find(_CONTEXT_KEY)
    if index < 0:
        return None
    try:
        # The blob is a JSON string holding more JSON, and it is followed by
        # further page markup, so it has to be decoded positionally.
        raw, _ = json.JSONDecoder().raw_decode(page, index + len(_CONTEXT_KEY))
        payload = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(payload, dict):
        return None
    gql = payload.get("gql_data")
    if not isinstance(gql, dict):
        return None
    media = gql.get("shortcode_media")
    return media if isinstance(media, dict) else None


def _media(media: dict[str, object]) -> InstagramMedia | None:
    caption = _caption(media)
    owner = media.get("owner")
    creator = None
    if isinstance(owner, dict):
        creator = str(owner.get("username") or "").strip() or None
    duration = media.get("video_duration")
    thumbnail = str(
        media.get("thumbnail_src") or media.get("display_url") or ""
    ).strip()
    if not caption and creator is None:
        return None
    return InstagramMedia(
        metadata=MediaMetadata(
            title=_title(caption),
            description=caption[:50_000],
            creator_name=creator,
            thumbnail_url=thumbnail or None,
            duration_seconds=(
                float(duration)
                if isinstance(duration, int | float) and duration >= 0
                else None
            ),
            counts=_counts(media),
        ),
        observations=_observations(media),
        media_url=str(media.get("video_url") or "").strip() or None,
    )


def _edge_count(media: dict[str, object], key: str) -> int | None:
    """Instagram wraps counts in a GraphQL edge: {"count": n}."""
    edge = media.get(key)
    if not isinstance(edge, dict):
        return None
    return _whole(edge.get("count"))


def _whole(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if value >= 0 else None


def _counts(media: dict[str, object]) -> SourceCounts:
    """Engagement counts from the same embed blob the caption comes from.

    The embed carries likes, comments and views but no publish timestamp and
    no repost count, so `published_at` stays empty for Instagram — which is
    why the feed cannot offer a "recent" order on this platform.
    """
    return SourceCounts(
        like_count=_edge_count(media, "edge_liked_by"),
        comment_count=_edge_count(media, "edge_media_to_comment"),
        view_count=_whole(media.get("video_view_count")),
    )


def _caption(media: dict[str, object]) -> str:
    edge = media.get("edge_media_to_caption")
    if not isinstance(edge, dict):
        return ""
    edges = edge.get("edges")
    if not isinstance(edges, list):
        return ""
    for entry in edges:
        if not isinstance(entry, dict):
            continue
        node = entry.get("node")
        if isinstance(node, dict) and node.get("text"):
            return str(node["text"]).strip()
    return ""


def _observations(media: dict[str, object]) -> list[VisualEvidence]:
    """Instagram's own alt text, when it wrote any. Absent on most videos."""
    described = str(media.get("accessibility_caption") or "").strip()
    if not described:
        return []
    return [
        VisualEvidence(
            text=described[:20_000],
            timestamp_seconds=None,
            provenance="instagram:altText",
        )
    ]


def _title(caption: str) -> str | None:
    """Instagram posts have no title field; the caption's first line is the closest."""
    for line in caption.splitlines():
        cleaned = re.sub(r"\s+", " ", line).strip(" _-—•·|")
        if 3 <= len(cleaned) <= _MAX_TITLE_CHARACTERS:
            return cleaned
    return None
