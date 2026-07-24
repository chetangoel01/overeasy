import logging
from uuid import uuid4

import httpx

from ladle.acquisition.models import SourceVideoDescriptor
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


class OEmbedThumbnailFetcher:
    """Best-effort thumbnail copy: platform oEmbed -> object storage.

    Platform CDN URLs expire, so bytes are copied into the private bucket
    and served through signed URLs. Every failure degrades to "no
    thumbnail" rather than failing the import.
    """

    def __init__(self, *, http: httpx.Client, storage: ObjectStorage) -> None:
        self._http = http
        self._storage = storage

    def fetch(self, source: SourceVideoDescriptor) -> str | None:
        try:
            thumbnail_url = self._resolve_thumbnail_url(source)
            if thumbnail_url is None:
                return None
            return self._copy_to_storage(source, thumbnail_url)
        except Exception:
            logger.warning(
                "thumbnail fetch failed for source %s",
                source.source_video_id,
                exc_info=True,
            )
            return None

    def _resolve_thumbnail_url(self, source: SourceVideoDescriptor) -> str | None:
        endpoint = _OEMBED_ENDPOINTS.get(source.platform)
        if endpoint is None:
            return None
        response = self._http.get(
            endpoint,
            params={"url": source.canonical_url, "format": "json"},
            follow_redirects=True,
        )
        response.raise_for_status()
        thumbnail_url = response.json().get("thumbnail_url")
        if not isinstance(thumbnail_url, str) or not thumbnail_url.startswith(
            "https://"
        ):
            return None
        return thumbnail_url

    def _copy_to_storage(
        self,
        source: SourceVideoDescriptor,
        thumbnail_url: str,
    ) -> str | None:
        response = self._http.get(thumbnail_url, follow_redirects=True)
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
        key = f"thumbnails/{source.source_video_id}/{uuid4().hex}{extension}"
        self._storage.put(key, response.content, content_type=content_type)
        return key
