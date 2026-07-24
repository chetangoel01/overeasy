from dataclasses import dataclass

import pytest

from ladle.imports.source_identity import (
    InvalidSourceURL,
    SourceIdentityParser,
    SourcePlatform,
    UnsupportedSource,
)


@dataclass
class FakeRedirectResolver:
    destination: str
    calls: list[str]

    def resolve(self, url: str) -> str:
        self.calls.append(url)
        return self.destination


@pytest.mark.parametrize(
    ("url", "platform", "video_id", "canonical_url"),
    [
        (
            "https://www.youtube.com/watch?v=abc_DEF-123&utm_source=test",
            SourcePlatform.YOUTUBE,
            "abc_DEF-123",
            "https://www.youtube.com/watch?v=abc_DEF-123",
        ),
        (
            "https://youtube.com/shorts/abc_DEF-123?feature=share",
            SourcePlatform.YOUTUBE,
            "abc_DEF-123",
            "https://www.youtube.com/watch?v=abc_DEF-123",
        ),
        (
            "https://youtu.be/abc_DEF-123?t=9",
            SourcePlatform.YOUTUBE,
            "abc_DEF-123",
            "https://www.youtube.com/watch?v=abc_DEF-123",
        ),
        (
            "https://www.tiktok.com/@chef/video/7481234567890123456?lang=en",
            SourcePlatform.TIKTOK,
            "7481234567890123456",
            "https://www.tiktok.com/@chef/video/7481234567890123456",
        ),
        (
            "https://www.instagram.com/reel/C9_recipe-ID/?igsh=test",
            SourcePlatform.INSTAGRAM,
            "C9_recipe-ID",
            "https://www.instagram.com/reel/C9_recipe-ID/",
        ),
        (
            "https://instagram.com/p/C9_post-ID/",
            SourcePlatform.INSTAGRAM,
            "C9_post-ID",
            "https://www.instagram.com/p/C9_post-ID/",
        ),
    ],
)
def test_direct_urls_map_to_stable_video_identity(
    url: str,
    platform: SourcePlatform,
    video_id: str,
    canonical_url: str,
) -> None:
    identity = SourceIdentityParser().parse(url)

    assert identity.platform == platform
    assert identity.platform_video_id == video_id
    assert identity.canonical_url == canonical_url


def test_tiktok_short_link_uses_safe_redirect_resolver() -> None:
    resolver = FakeRedirectResolver(
        destination="https://www.tiktok.com/@chef/video/7481234567890123456",
        calls=[],
    )

    identity = SourceIdentityParser(redirect_resolver=resolver).parse(
        "https://vm.tiktok.com/ZMshort/"
    )

    assert identity.platform_video_id == "7481234567890123456"
    assert resolver.calls == ["https://vm.tiktok.com/ZMshort/"]


@pytest.mark.parametrize(
    "url",
    [
        "http://www.youtube.com/watch?v=abc_DEF-123",
        "https://youtube.com.evil.test/watch?v=abc_DEF-123",
        "https://user:password@www.youtube.com/watch?v=abc_DEF-123",
        "https://www.youtube.com:8443/watch?v=abc_DEF-123",
        "https://manual.ladle.local/abc",
        "not a url",
    ],
)
def test_unsafe_or_non_import_urls_are_rejected(url: str) -> None:
    with pytest.raises((InvalidSourceURL, UnsupportedSource)):
        SourceIdentityParser().parse(url)


def test_short_link_without_resolver_is_rejected() -> None:
    with pytest.raises(InvalidSourceURL):
        SourceIdentityParser().parse("https://vm.tiktok.com/ZMshort/")
