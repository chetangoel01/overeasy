import re
from dataclasses import dataclass
from enum import StrEnum
from typing import Protocol
from urllib.parse import SplitResult, parse_qs, urlsplit


class InvalidSourceURL(Exception):
    pass


class UnsupportedSource(Exception):
    pass


class SourcePlatform(StrEnum):
    YOUTUBE = "youtube"
    TIKTOK = "tiktok"
    INSTAGRAM = "instagram"


@dataclass(frozen=True)
class SourceIdentity:
    platform: SourcePlatform
    platform_video_id: str
    canonical_url: str


class RedirectResolver(Protocol):
    def resolve(self, url: str) -> str: ...


_VIDEO_IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]{6,64}$")
_TIKTOK_PATH = re.compile(
    r"^/@(?P<username>[A-Za-z0-9._-]+)/video/(?P<video_id>[0-9]{6,32})/?$"
)
_INSTAGRAM_PATH = re.compile(r"^/(?P<kind>reel|p)/(?P<video_id>[A-Za-z0-9_-]{3,64})/?$")


class SourceIdentityParser:
    def __init__(
        self,
        *,
        redirect_resolver: RedirectResolver | None = None,
    ) -> None:
        self._redirect_resolver = redirect_resolver

    def parse(self, url: str) -> SourceIdentity:
        parsed = self._validated_components(url)
        hostname = parsed.hostname.casefold() if parsed.hostname else ""
        if hostname == "vm.tiktok.com":
            if self._redirect_resolver is None:
                raise InvalidSourceURL("short links require safe resolution")
            destination = self._redirect_resolver.resolve(url)
            destination_parts = self._validated_components(destination)
            if (
                destination_parts.hostname is not None
                and destination_parts.hostname.casefold() == "vm.tiktok.com"
            ):
                raise InvalidSourceURL("short link did not resolve")
            return self._parse_direct(destination_parts)
        return self._parse_direct(parsed)

    def _parse_direct(self, parsed: SplitResult) -> SourceIdentity:
        hostname = parsed.hostname.casefold() if parsed.hostname else ""
        path = parsed.path

        if hostname in {"youtube.com", "www.youtube.com", "m.youtube.com"}:
            video_id: str | None = None
            if path == "/watch":
                video_id = parse_qs(parsed.query).get("v", [None])[0]
            elif path.startswith("/shorts/"):
                video_id = path.removeprefix("/shorts/").strip("/").split("/")[0]
            return self._youtube(video_id)

        if hostname == "youtu.be":
            return self._youtube(path.strip("/").split("/")[0])

        if hostname in {"tiktok.com", "www.tiktok.com", "m.tiktok.com"}:
            match = _TIKTOK_PATH.fullmatch(path)
            if match is None:
                raise InvalidSourceURL("invalid TikTok video path")
            username = match.group("username")
            video_id = match.group("video_id")
            return SourceIdentity(
                platform=SourcePlatform.TIKTOK,
                platform_video_id=video_id,
                canonical_url=f"https://www.tiktok.com/@{username}/video/{video_id}",
            )

        if hostname in {"instagram.com", "www.instagram.com"}:
            match = _INSTAGRAM_PATH.fullmatch(path)
            if match is None:
                raise InvalidSourceURL("invalid Instagram video path")
            kind = match.group("kind")
            video_id = match.group("video_id")
            return SourceIdentity(
                platform=SourcePlatform.INSTAGRAM,
                platform_video_id=video_id,
                canonical_url=f"https://www.instagram.com/{kind}/{video_id}/",
            )

        raise UnsupportedSource(hostname)

    def _youtube(self, video_id: str | None) -> SourceIdentity:
        if video_id is None or _VIDEO_IDENTIFIER.fullmatch(video_id) is None:
            raise InvalidSourceURL("invalid YouTube video ID")
        return SourceIdentity(
            platform=SourcePlatform.YOUTUBE,
            platform_video_id=video_id,
            canonical_url=f"https://www.youtube.com/watch?v={video_id}",
        )

    def _validated_components(self, url: str) -> SplitResult:
        try:
            parsed = urlsplit(url)
            port = parsed.port
        except (TypeError, ValueError) as error:
            raise InvalidSourceURL("invalid URL") from error
        if (
            parsed.scheme.casefold() != "https"
            or parsed.hostname is None
            or parsed.username is not None
            or parsed.password is not None
            or port not in (None, 443)
        ):
            raise InvalidSourceURL("source must be an HTTPS public URL")
        return parsed
