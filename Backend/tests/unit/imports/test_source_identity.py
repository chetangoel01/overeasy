from dataclasses import dataclass

import pytest

from ladle.acquisition.models import MediaKind
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
            "https://www.tiktok.com/@chef/photo/7481234567890123456?lang=en",
            SourcePlatform.TIKTOK,
            "7481234567890123456",
            "https://www.tiktok.com/@chef/photo/7481234567890123456",
        ),
        (
            "https://www.instagram.com/reel/C9_recipe-ID/?igsh=test",
            SourcePlatform.INSTAGRAM,
            "C9_recipe-ID",
            "https://www.instagram.com/reel/C9_recipe-ID/",
        ),
        (
            "https://www.instagram.com/share/reel/C9_recipe-ID/?igsh=test",
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
        (
            "https://m.instagram.com/reel/C9_recipe-ID/",
            SourcePlatform.INSTAGRAM,
            "C9_recipe-ID",
            "https://www.instagram.com/reel/C9_recipe-ID/",
        ),
        (
            "https://www.instagram.com/reels/C9_recipe-ID/?igsh=test",
            SourcePlatform.INSTAGRAM,
            "C9_recipe-ID",
            "https://www.instagram.com/reel/C9_recipe-ID/",
        ),
        (
            "https://www.youtube.com/live/abc_DEF-123?feature=share",
            SourcePlatform.YOUTUBE,
            "abc_DEF-123",
            "https://www.youtube.com/watch?v=abc_DEF-123",
        ),
        (
            "https://www.youtube.com/embed/abc_DEF-123?autoplay=1",
            SourcePlatform.YOUTUBE,
            "abc_DEF-123",
            "https://www.youtube.com/watch?v=abc_DEF-123",
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


def test_tiktok_vt_short_link_uses_safe_redirect_resolver() -> None:
    resolver = FakeRedirectResolver(
        destination="https://www.tiktok.com/@chef/video/7481234567890123456",
        calls=[],
    )

    identity = SourceIdentityParser(redirect_resolver=resolver).parse(
        "https://vt.tiktok.com/ZS4NEvuUH/"
    )

    assert identity.platform_video_id == "7481234567890123456"
    assert resolver.calls == ["https://vt.tiktok.com/ZS4NEvuUH/"]


def test_tiktok_web_share_link_uses_safe_redirect_resolver() -> None:
    resolver = FakeRedirectResolver(
        destination="https://www.tiktok.com/@chef/video/7481234567890123456",
        calls=[],
    )

    identity = SourceIdentityParser(redirect_resolver=resolver).parse(
        "https://www.tiktok.com/t/ZTshort/"
    )

    assert identity.platform_video_id == "7481234567890123456"
    assert resolver.calls == ["https://www.tiktok.com/t/ZTshort/"]


@pytest.mark.parametrize(
    "url",
    [
        "http://www.youtube.com/watch?v=abc_DEF-123",
        "https://youtube.com.evil.test/watch?v=abc_DEF-123",
        "https://user:password@www.youtube.com/watch?v=abc_DEF-123",
        "https://www.youtube.com:8443/watch?v=abc_DEF-123",
        "https://www.youtube.com/live/abc",
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


@pytest.mark.parametrize(
    "url",
    [
        # A carousel is /photo/<numeric id>, and nothing else on the path.
        "https://www.tiktok.com/@chef/photo/abc",
        "https://www.tiktok.com/@chef/photo/",
        "https://www.tiktok.com/@chef/photos/7481234567890123456",
        "https://www.tiktok.com/@chef/picture/7481234567890123456",
        "https://www.tiktok.com/@chef/photo/7481234567890123456/extra",
    ],
)
def test_malformed_photo_paths_are_still_rejected(url: str) -> None:
    with pytest.raises(InvalidSourceURL):
        SourceIdentityParser().parse(url)


@pytest.mark.parametrize(
    ("url", "kind"),
    [
        (
            "https://www.tiktok.com/@chef/photo/7481234567890123456",
            MediaKind.PHOTO,
        ),
        (
            "https://www.tiktok.com/@chef/video/7481234567890123456",
            MediaKind.VIDEO,
        ),
        # Instagram tells us at fetch time, not in the path: /p/ serves image
        # carousels, video carousels and single videos alike.
        ("https://www.instagram.com/p/C9_post-ID/", MediaKind.VIDEO),
        ("https://www.youtube.com/watch?v=abc_DEF-123", MediaKind.VIDEO),
    ],
)
def test_media_kind_rides_on_the_canonical_url(url: str, kind: MediaKind) -> None:
    assert SourceIdentityParser().parse(url).media_kind == kind


def test_tiktok_photo_short_link_resolves_to_a_photo_identity() -> None:
    resolver = FakeRedirectResolver(
        destination="https://www.tiktok.com/@chef/photo/7481234567890123456",
        calls=[],
    )

    identity = SourceIdentityParser(redirect_resolver=resolver).parse(
        "https://vt.tiktok.com/ZS4NEvuUH/"
    )

    assert identity.canonical_url == (
        "https://www.tiktok.com/@chef/photo/7481234567890123456"
    )
    assert identity.media_kind == MediaKind.PHOTO
