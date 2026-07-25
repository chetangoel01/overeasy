import json
from uuid import uuid4

from ladle.acquisition.free.instagram import InstagramEmbedClient
from ladle.acquisition.models import SourceVideoDescriptor

CAPTION = (
    "Creamy Tuscan Butter Salmon\n"
    "__\n"
    "4 salmon fillets\n"
    "2 tbsp butter (28g)\n"
    "1 cup heavy cream (235ml)\n"
    "Sear the salmon, then simmer the sauce until it thickens."
)


def source(shortcode: str = "CYWyuCZodzP") -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id=shortcode,
        canonical_url=f"https://www.instagram.com/reel/{shortcode}/",
        source_revision="1",
    )


def page(
    *,
    caption: str = CAPTION,
    username: str = "serenagwolf",
    duration: float | None = 57.234,
    alt_text: str | None = None,
) -> str:
    media: dict[str, object] = {
        "edge_media_to_caption": {"edges": [{"node": {"text": caption}}]},
        "owner": {"username": username},
        "video_duration": duration,
        "thumbnail_src": "https://cdn.instagram.com/thumb.jpg",
        "is_video": True,
    }
    if alt_text is not None:
        media["accessibility_caption"] = alt_text
    blob = json.dumps(json.dumps({"gql_data": {"shortcode_media": media}}))
    return (
        '<html><script>window.__additionalData={"contextJSON":'
        + blob
        + ',"other":1};</script><div>markup after the blob</div></html>'
    )


class Fetcher:
    def __init__(self, body: str | None) -> None:
        self.body = body
        self.urls: list[str] = []

    def fetch_raw(self, url: str) -> str:
        self.urls.append(url)
        if self.body is None:
            raise OSError("blocked")
        return self.body

    def fetch_text(self, url: str) -> str:
        return self.fetch_raw(url)


def test_embed_page_yields_caption_creator_and_duration() -> None:
    fetcher = Fetcher(page())

    media = InstagramEmbedClient(fetcher=fetcher).metadata(source())

    assert media is not None
    assert media.metadata.creator_name == "serenagwolf"
    assert media.metadata.duration_seconds == 57.234
    assert "2 tbsp butter (28g)" in media.metadata.description
    # No title field on Instagram; the caption's first line is the closest thing.
    assert media.metadata.title == "Creamy Tuscan Butter Salmon"
    assert fetcher.urls == [
        "https://www.instagram.com/reel/CYWyuCZodzP/embed/captioned/"
    ]


def test_alt_text_becomes_untimed_visual_evidence() -> None:
    fetcher = Fetcher(page(alt_text="May be an image of salmon and cream sauce"))

    media = InstagramEmbedClient(fetcher=fetcher).metadata(source())

    assert media is not None
    assert media.observations[0].provenance == "instagram:altText"
    assert media.observations[0].timestamp_seconds is None


def test_missing_alt_text_yields_no_observations() -> None:
    media = InstagramEmbedClient(fetcher=Fetcher(page())).metadata(source())

    assert media is not None
    assert media.observations == []


def test_blocked_embed_is_survivable() -> None:
    assert InstagramEmbedClient(fetcher=Fetcher(None)).metadata(source()) is None


def test_page_without_a_blob_is_survivable() -> None:
    fetcher = Fetcher("<html>login required</html>")

    assert InstagramEmbedClient(fetcher=fetcher).metadata(source()) is None


def test_shortcode_is_validated_before_building_a_url() -> None:
    fetcher = Fetcher(page())

    media = InstagramEmbedClient(fetcher=fetcher).metadata(source("../../evil"))

    assert media is None
    assert fetcher.urls == []
