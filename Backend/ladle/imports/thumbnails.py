import logging
from dataclasses import dataclass
from uuid import uuid4

import httpx

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.infrastructure.dns import (
    DNSResolver,
    PinnedHTTPClient,
    SystemDNSResolver,
)
from ladle.infrastructure.object_storage import ObjectStorage

logger = logging.getLogger(__name__)

_MAX_THUMBNAIL_BYTES = 5 * 1024 * 1024
_OEMBED_ENDPOINTS = {
    "tiktok": "https://www.tiktok.com/oembed",
    "youtube": "https://www.youtube.com/oembed",
}
_ALLOWED_CONTENT_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}


@dataclass(frozen=True)
class ThumbnailAsset:
    data: bytes
    content_type: str
    extension: str


class OEmbedThumbnailFetcher:
    """Best-effort thumbnail copy: platform oEmbed -> object storage.

    Platform CDN URLs expire, so bytes are copied into the private bucket
    and served through signed URLs. Every failure degrades to "no
    thumbnail" rather than failing the import.
    """

    def __init__(
        self,
        *,
        http: httpx.Client,
        storage: ObjectStorage,
        dns: DNSResolver | None = None,
    ) -> None:
        self._http = PinnedHTTPClient(
            dns=dns or SystemDNSResolver(),
            client=http,
        )
        self._storage = storage

    def fetch(
        self,
        source: SourceVideoDescriptor,
        *,
        candidate_url: str | None = None,
    ) -> str | None:
        asset = self.download(source, candidate_url=candidate_url)
        return self.store(source, asset) if asset is not None else None

    def download(
        self,
        source: SourceVideoDescriptor,
        *,
        candidate_url: str | None = None,
    ) -> ThumbnailAsset | None:
        try:
            thumbnail_url = self._resolve_thumbnail_url(
                source,
                candidate_url=candidate_url,
            )
            if thumbnail_url is None:
                return None
            response = self._http.get(
                thumbnail_url,
                max_bytes=_MAX_THUMBNAIL_BYTES,
            )
            response.raise_for_status()
            content_type = (
                response.headers.get("content-type", "image/jpeg")
                .split(";")[0]
                .strip()
                .lower()
            )
            extension = _ALLOWED_CONTENT_TYPES.get(content_type)
            if extension is None or len(response.content) > _MAX_THUMBNAIL_BYTES:
                return None
            return ThumbnailAsset(
                data=response.content,
                content_type=content_type,
                extension=extension,
            )
        except Exception:
            logger.warning(
                "thumbnail fetch failed for source %s",
                source.source_video_id,
                exc_info=True,
            )
            return None

    def store(
        self,
        source: SourceVideoDescriptor,
        asset: ThumbnailAsset,
    ) -> str | None:
        key = f"thumbnails/{source.source_video_id}/{uuid4().hex}{asset.extension}"
        try:
            self._storage.put(
                key,
                asset.data,
                content_type=asset.content_type,
            )
        except Exception:
            logger.warning(
                "thumbnail storage failed for source %s",
                source.source_video_id,
                exc_info=True,
            )
            return None
        return key

    def _resolve_thumbnail_url(
        self,
        source: SourceVideoDescriptor,
        *,
        candidate_url: str | None,
    ) -> str | None:
        if candidate_url is not None and candidate_url.startswith("https://"):
            return candidate_url
        endpoint = _OEMBED_ENDPOINTS.get(source.platform)
        if endpoint is None:
            return None
        response = self._http.get(
            endpoint,
            params={"url": source.canonical_url, "format": "json"},
            max_bytes=256 * 1024,
        )
        response.raise_for_status()
        thumbnail_url = response.json().get("thumbnail_url")
        if not isinstance(thumbnail_url, str) or not thumbnail_url.startswith(
            "https://"
        ):
            return None
        return thumbnail_url
