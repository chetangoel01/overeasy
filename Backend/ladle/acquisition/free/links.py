"""Creator-published recipe pages, reached deterministically and fetched safely.

Only two paths lead here: a URL the creator wrote in their own caption, and a
Substack post whose slug matches the video on the creator's own subdomain. Both
are traceable back to the creator. Open web search is deliberately absent — it
returns plausible pages by unrelated authors, and attributing a stranger's
recipe to a creator is worse than returning nothing.
"""

import html
import ipaddress
import logging
import re
import socket
from typing import Protocol
from urllib.parse import quote, urlsplit, urlunsplit

import httpx

LOGGER = logging.getLogger(__name__)

_URL = re.compile(r"https?://[^\s<>()\"']+", re.IGNORECASE)
_BARE_DOMAIN = re.compile(
    r"(?<![@\w.])(?:[a-z0-9-]+\.)+(?:com|net|org|co|io|me|app|blog|dev|kitchen|"
    r"recipes|food)(?:/[^\s<>()\"']*)?",
    re.IGNORECASE,
)
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
_SCRIPTISH = re.compile(
    r"(?is)<(script|style|noscript|svg|iframe|head)[^>]*>.*?</\1>",
)
_TAG = re.compile(r"(?s)<[^>]+>")
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

    This closes SSRF via redirect and via literal private addresses. It does not
    defeat a deliberate DNS-rebinding race, which would need connection-level IP
    pinning; egress filtering remains the backstop for that.
    """

    def __init__(
        self,
        *,
        http: httpx.Client,
        max_redirects: int = _MAX_REDIRECTS,
        max_response_bytes: int = _MAX_RESPONSE_BYTES,
    ) -> None:
        self._http = http
        self._max_redirects = max_redirects
        self._max_response_bytes = max_response_bytes

    def fetch_text(self, url: str) -> str:
        return _readable(self.fetch_raw(url))

    def fetch_raw(self, url: str) -> str:
        current = url
        for _ in range(self._max_redirects + 1):
            target = _validated(current)
            response = self._http.get(
                target,
                headers={
                    "User-Agent": _USER_AGENT,
                    "Accept": "text/html,application/xhtml+xml,application/xml",
                },
                follow_redirects=False,
            )
            if response.is_redirect:
                location = response.headers.get("location")
                if not location:
                    raise UnsafeURL("redirect without a location")
                current = str(httpx.URL(target).join(location))
                continue
            response.raise_for_status()
            content_type = response.headers.get("content-type", "")
            if not any(kind in content_type for kind in ("html", "xml", "text")):
                return ""
            return response.text[: self._max_response_bytes]
        raise UnsafeURL("too many redirects")


def _validated(url: str) -> str:
    parts = urlsplit(url)
    if parts.scheme not in ("http", "https"):
        raise UnsafeURL(f"unsupported scheme: {parts.scheme!r}")
    host = (parts.hostname or "").strip()
    if not host:
        raise UnsafeURL("missing host")
    for address in _resolve(host):
        if not address.is_global or address.is_multicast:
            raise UnsafeURL(f"host {host} resolves to non-public address {address}")
    # Re-encode so control characters in a caption cannot smuggle a second request.
    return urlunsplit(
        (
            parts.scheme,
            parts.netloc,
            quote(parts.path, safe="/%:@!$&'()*+,;=~-._"),
            quote(parts.query, safe="/?=&%:@!$'()*+,;~-._"),
            "",
        )
    )


def _resolve(host: str) -> list[ipaddress.IPv4Address | ipaddress.IPv6Address]:
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except socket.gaierror as error:
        raise UnsafeURL(f"cannot resolve {host}") from error
    addresses = []
    for info in infos:
        raw = info[4][0]
        try:
            addresses.append(ipaddress.ip_address(raw))
        except ValueError:
            continue
    if not addresses:
        raise UnsafeURL(f"cannot resolve {host}")
    return addresses


def _host_of(url: str) -> str:
    try:
        parts = urlsplit(url)
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
    stripped = _TAG.sub(" ", _SCRIPTISH.sub(" ", raw))
    text = _WHITESPACE.sub(" ", html.unescape(stripped)).strip()
    return text[:_MAX_DOCUMENT_CHARACTERS]
