"""Creator-published recipe pages, reached deterministically and fetched safely.

Only two paths lead here: a URL the creator wrote in their own caption, and a
Substack post whose slug matches the video on the creator's own subdomain. Both
are traceable back to the creator. Open web search is deliberately absent — it
returns plausible pages by unrelated authors, and attributing a stranger's
recipe to a creator is worse than returning nothing.
"""

import html
import logging
import re
from typing import Protocol
from urllib.parse import urlsplit

import httpx

from ladle.infrastructure.dns import (
    DNSResolver,
    PinnedHTTPClient,
    SystemDNSResolver,
    UnsafeNetworkTarget,
)

LOGGER = logging.getLogger(__name__)

_URL = re.compile(r"https?://[^\s<>()\"']+", re.IGNORECASE)
_BARE_DOMAIN = re.compile(
    r"(?<![@\w.])(?:[a-z0-9-]+\.)+(?:com|net|org|co|io|me|app|blog|dev|kitchen|"
    r"recipes|food)(?:/[^\s<>()\"']*)?",
    re.IGNORECASE,
)


def belongs_to_creator(url: str, creator_name: str | None) -> bool:
    """Whether a link looks like the creator's own site rather than a sponsor.

    Handles and domains agree more often than not once punctuation is dropped:
    "justine_snacks" writes justinesnacks.com. Short handles are refused
    because a three-letter name matches half the web by accident.
    """

    handle = re.sub(r"[^a-z0-9]", "", (creator_name or "").casefold())
    if len(handle) < 5:
        return False
    host = (urlsplit(url).hostname or "").casefold().removeprefix("www.")
    return handle in re.sub(r"[^a-z0-9]", "", host)


_SOCIAL_HOSTS = (
    "tiktok.com",
    "instagram.com",
    "youtube.com",
    "youtu.be",
    "facebook.com",
    "twitter.com",
    "x.com",
    "threads.net",
    "pinterest.com",
    "snapchat.com",
)
_PROMO_TAIL = re.compile(
    r"(find (all )?my recipes.*|full (written )?recipe.*|link in (my )?bio.*|"
    r"follow (me|for).*|subscribe .*)",
    re.IGNORECASE,
)
_SCRIPTISH_NAMES = ("script", "style", "noscript", "svg", "iframe", "head")
_SCRIPTISH_OPEN = re.compile(rf"(?i)<({'|'.join(_SCRIPTISH_NAMES)})[^>]*>")
_SCRIPTISH_CLOSE = {name: re.compile(rf"(?i)</{name}>") for name in _SCRIPTISH_NAMES}
_WHITESPACE = re.compile(r"\s+")
_LOC = re.compile(r"<loc>([^<]+)</loc>")

_MAX_DOCUMENT_CHARACTERS = 16_000
_MAX_RESPONSE_BYTES = 2_000_000
_MAX_REDIRECTS = 3
_USER_AGENT = "LadleRecipeFetcher/1.0 (+https://ladle.app)"


class UnsafeURL(ValueError):
    pass


def caption_links(text: str, *, limit: int = 3) -> list[str]:
    """External links the creator wrote in their own caption."""
    value = str(text or "")
    explicit = _URL.findall(value)
    bare = _BARE_DOMAIN.findall(_URL.sub(" ", value))
    found: list[str] = []
    seen: set[str] = set()
    for raw in [*explicit, *(f"https://{item}" for item in bare)]:
        cleaned = raw.rstrip(").,!;:'\"…-")
        try:
            host = _host_of(cleaned)
        except UnsafeURL:
            continue
        if _is_social(host):
            continue
        key = cleaned.casefold()
        if key in seen:
            continue
        seen.add(key)
        found.append(cleaned)
        if len(found) >= limit:
            break
    return found


def dish_terms(title: str, *, limit: int = 16) -> list[str]:
    """Dish words from a post title, with promo copy, tags and handles removed."""
    value = _PROMO_TAIL.sub(" ", str(title or ""))
    value = re.sub(r"[#@]\S+", " ", value)
    value = re.sub(r"[^\w\s'-]", " ", value)
    return [word.casefold() for word in value.split() if len(word) > 2][:limit]


def substack_candidates(
    creator: str,
    title: str,
    *,
    fetcher: "LinkFetcher",
    minimum_overlap: int = 2,
) -> list[str]:
    """Posts on the creator's own Substack whose slug matches this video.

    Creator handles usually match the subdomain and Substack sitemaps are public,
    so this resolves "link in bio" without guessing at authorship.
    """
    handle = re.sub(r"[^a-z0-9-]", "", str(creator or "").casefold())
    words = set(dish_terms(title))
    if not handle or not words:
        return []
    try:
        sitemap = fetcher.fetch_raw(f"https://{handle}.substack.com/sitemap.xml")
    except (UnsafeURL, OSError, httpx.HTTPError) as error:
        LOGGER.info("Substack sitemap unavailable for %s: %s", handle, error)
        return []
    posts = [loc for loc in _LOC.findall(sitemap) if "/p/" in loc]
    for child in [loc for loc in _LOC.findall(sitemap) if loc.endswith(".xml")][:3]:
        if posts:
            break
        try:
            posts = [
                loc for loc in _LOC.findall(fetcher.fetch_raw(child)) if "/p/" in loc
            ]
        except (UnsafeURL, OSError, httpx.HTTPError):
            continue

    def overlap(post_url: str) -> int:
        slug = post_url.rstrip("/").rsplit("/", 1)[-1]
        return len(words & set(slug.replace("-", " ").split()))

    # Only the single best match. A creator's archive is full of near-misses —
    # "creamy-calabrian-chili-chickpeas" scores well against a lemon-chickpea
    # video, and attaching it would hand the extractor a different recipe.
    ranked = sorted(posts, key=overlap, reverse=True)
    best = next(iter(ranked), None)
    if best is None or overlap(best) < minimum_overlap:
        return []
    return [best]


class LinkFetcher(Protocol):
    def fetch_text(self, url: str) -> str: ...

    def fetch_raw(self, url: str) -> str: ...


class SafeLinkFetcher:
    """Fetches creator-supplied URLs without letting them reach internal hosts.

    Caption text is attacker-controlled: anyone can post a video whose caption
    points at a cloud metadata endpoint. Every hop is re-resolved and every
    resolved address is checked before the request is made.

    The connection is pinned to the address that passed validation. Every
    redirect is resolved, validated, and pinned independently.
    """

    def __init__(
        self,
        *,
        http: httpx.Client,
        dns: DNSResolver | None = None,
        max_redirects: int = _MAX_REDIRECTS,
        max_response_bytes: int = _MAX_RESPONSE_BYTES,
    ) -> None:
        self._http = PinnedHTTPClient(
            dns=dns or SystemDNSResolver(),
            client=http,
            maximum_redirects=max_redirects,
        )
        self._max_response_bytes = max_response_bytes

    def fetch_text(self, url: str) -> str:
        body, content_type = self._get(url)
        # A creator link that turns out to be a binary is not a recipe page.
        if not any(kind in content_type for kind in ("html", "xml", "text")):
            return ""
        return _readable(body)

    def fetch_raw(self, url: str) -> str:
        """Body as text, whatever the server claims it is.

        TikTok serves its WebVTT caption tracks as `video/mp4`, so callers that
        know what they asked for must be able to bypass the content-type gate.
        """
        return self._get(url)[0]

    def _get(self, url: str) -> tuple[str, str]:
        try:
            response = self._http.get(
                url,
                headers={
                    "User-Agent": _USER_AGENT,
                    "Accept": "text/html,application/xhtml+xml,application/xml",
                },
                max_bytes=self._max_response_bytes,
            )
            response.raise_for_status()
            return (
                response.text,
                response.headers.get("content-type", ""),
            )
        except UnsafeNetworkTarget as error:
            raise UnsafeURL(str(error)) from error


def _host_of(url: str) -> str:
    try:
        parts = urlsplit(url)
        # Reading the port forces its parse: "host:abc" raises here, at the
        # caption boundary, instead of as httpx.InvalidURL mid-fetch.
        _ = parts.port
    except ValueError as error:
        raise UnsafeURL(str(error)) from error
    if parts.scheme not in ("http", "https"):
        raise UnsafeURL("unsupported scheme")
    host = (parts.hostname or "").casefold().removeprefix("www.")
    if not host or "." not in host:
        raise UnsafeURL("missing host")
    return host


def _is_social(host: str) -> bool:
    return any(
        host == social or host.endswith(f".{social}") for social in _SOCIAL_HOSTS
    )


def _readable(raw: str) -> str:
    stripped = _without_tags(_without_scriptish(raw))
    text = _WHITESPACE.sub(" ", html.unescape(stripped)).strip()
    return text[:_MAX_DOCUMENT_CHARACTERS]


def _without_scriptish(raw: str) -> str:
    """Drop <script>...</script>-style blocks in one linear pass.

    The obvious one-liner — a lazy `<tag>[^>]*>.*?</tag>` regex — backtracks
    quadratically when opening tags never close, and 2 MB of attacker HTML
    (exactly the response cap) holds the worker's only thread for the better
    part of an hour inside one uninterruptible C call. Forward searches give
    the same result linearly: the scan position only moves forward, and a tag
    name that never closes again is remembered, so each name costs at most
    one failed search over the remainder.
    """
    parts: list[str] = []
    position = 0
    unclosed: set[str] = set()
    while match := _SCRIPTISH_OPEN.search(raw, position):
        name = match.group(1).casefold()
        closing = (
            None
            if name in unclosed
            else _SCRIPTISH_CLOSE[name].search(raw, match.end())
        )
        if closing is None:
            # No close anywhere ahead. Leave the tag for _without_tags, the
            # way the old regex left an unmatched opening tag alone.
            unclosed.add(name)
            parts.append(raw[position : match.end()])
            position = match.end()
            continue
        parts.append(raw[position : match.start()])
        parts.append(" ")
        position = closing.end()
    parts.append(raw[position:])
    return "".join(parts)


def _without_tags(raw: str) -> str:
    """Replace every complete <...> region with a space, linearly.

    `<[^>]+>` has the same quadratic shape as above: with no ">" left in the
    body it re-scans to end-of-string from every "<".
    """
    parts: list[str] = []
    position = 0
    while (opening := raw.find("<", position)) != -1:
        closing = raw.find(">", opening + 1)
        if closing == -1:
            break
        parts.append(raw[position:opening])
        parts.append(" ")
        position = closing + 1
    parts.append(raw[position:])
    return "".join(parts)
