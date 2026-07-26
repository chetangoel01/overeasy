from collections.abc import Sequence
from dataclasses import dataclass
from uuid import uuid4

import httpx

from ladle.acquisition.models import SourceVideoDescriptor
from ladle.imports.thumbnails import OEmbedThumbnailFetcher


@dataclass
class FakeDNS:
    values: dict[str, Sequence[str]]

    def resolve(self, hostname: str) -> Sequence[str]:
        return self.values[hostname]


class RecordingStorage:
    def __init__(self) -> None:
        self.puts: list[tuple[str, bytes, str]] = []

    def put(self, key: str, data: bytes, *, content_type: str) -> None:
        self.puts.append((key, data, content_type))


def test_provider_returned_thumbnail_is_revalidated_before_download() -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            json={"thumbnail_url": "https://169.254.169.254/metadata"},
        )

    storage = RecordingStorage()
    fetcher = OEmbedThumbnailFetcher(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        dns=FakeDNS({"www.youtube.com": ["93.184.216.34"]}),
        storage=storage,  # type: ignore[arg-type]
    )
    source = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="youtube",
        platform_video_id="video-1",
        canonical_url="https://www.youtube.com/watch?v=video-1",
        source_revision="1",
    )

    assert fetcher.fetch(source) is None
    assert len(requests) == 1
    assert requests[0].url.host == "93.184.216.34"
    assert storage.puts == []
