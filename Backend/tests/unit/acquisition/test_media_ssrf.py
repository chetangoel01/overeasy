from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

import httpx

from ladle.acquisition.audio import MediaAudioSource
from ladle.acquisition.models import SourceVideoDescriptor


@dataclass
class FakeDNS:
    values: dict[str, Sequence[str]]

    def resolve(self, hostname: str) -> Sequence[str]:
        return self.values[hostname]


def test_provider_returned_media_url_is_rejected_before_download(
    tmp_path: Path,
) -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, content=b"private")

    source = MediaAudioSource(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        dns=FakeDNS({"media.example": ["10.0.0.7"]}),
    )
    descriptor = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id="shortcode",
        canonical_url="https://www.instagram.com/reel/shortcode/",
        source_revision="1",
    )

    assert (
        source.media(
            descriptor,
            media_url="https://media.example/video.mp4",
            work_dir=tmp_path,
        )
        is None
    )
    assert requests == []


def test_malformed_media_url_is_skipped_not_fatal(tmp_path: Path) -> None:
    def respond(request: httpx.Request) -> httpx.Response:
        raise AssertionError("no request should be made for a malformed URL")

    source = MediaAudioSource(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        dns=FakeDNS({}),
    )
    descriptor = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id="shortcode",
        canonical_url="https://www.instagram.com/reel/shortcode/",
        source_revision="1",
    )

    assert (
        source.media(
            descriptor,
            media_url="https://media.example:abc/video.mp4",
            work_dir=tmp_path,
        )
        is None
    )


def test_provider_returned_public_media_is_pinned_and_bounded(
    tmp_path: Path,
) -> None:
    requests: list[httpx.Request] = []

    def respond(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(200, content=b"public-media")

    source = MediaAudioSource(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        dns=FakeDNS({"media.example": ["93.184.216.34"]}),
        max_media_bytes=32,
    )
    descriptor = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id="shortcode",
        canonical_url="https://www.instagram.com/reel/shortcode/",
        source_revision="1",
    )

    downloaded = source.media(
        descriptor,
        media_url="https://media.example/video.mp4",
        media_headers={
            "Cookie": "tt_chain_token=public",
            "Referer": "https://www.tiktok.com/@cook/video/1",
        },
        work_dir=tmp_path,
    )

    assert downloaded is not None
    assert downloaded.read_bytes() == b"public-media"
    assert requests[0].url.host == "93.184.216.34"
    assert requests[0].headers["host"] == "media.example"
    assert requests[0].headers["cookie"] == "tt_chain_token=public"
    assert requests[0].headers["referer"] == ("https://www.tiktok.com/@cook/video/1")
