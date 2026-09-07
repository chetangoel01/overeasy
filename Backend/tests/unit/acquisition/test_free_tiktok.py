import json

from ladle.acquisition.free.tiktok import TikTokPageClient
from ladle.acquisition.models import MediaKind

VTT = """WEBVTT

00:00:00.040 --> 00:00:03.240
add two cans of chickpeas and a cup of cream

00:00:03.241 --> 00:00:06.100
then simmer until it thickens
"""


def page(
    *,
    subtitle_infos: list[dict[str, object]] | None = None,
    stickers: list[dict[str, object]] | None = None,
    image_post: dict[str, object] | None = None,
    description: str = "",
) -> str:
    item: dict[str, object] = {
        "desc": description,
        "video": {"subtitleInfos": subtitle_infos or []},
        "stickersOnItem": stickers or [],
    }
    if image_post is not None:
        item["imagePost"] = image_post
    payload = {
        "__DEFAULT_SCOPE__": {"webapp.video-detail": {"itemInfo": {"itemStruct": item}}}
    }
    return (
        '<html><script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">'
        f"{json.dumps(payload)}</script></html>"
    )


ENGLISH_TRACK = {
    "Url": "https://cdn.tiktokcdn-us.com/captions/eng.vtt",
    "Format": "webvtt",
    "LanguageCodeName": "eng-US",
    "Source": "ASR",
}


class Fetcher:
    def __init__(self, responses: dict[str, str]) -> None:
        self.responses = responses
        self.urls: list[str] = []

    def fetch_raw(self, url: str) -> str:
        self.urls.append(url)
        if url not in self.responses:
            raise OSError("not found")
        return self.responses[url]

    def fetch_text(self, url: str) -> str:
        return self.fetch_raw(url)


VIDEO_URL = "https://www.tiktok.com/@creator/video/1"


def test_asr_track_becomes_timed_generated_transcript() -> None:
    fetcher = Fetcher(
        {
            VIDEO_URL: page(subtitle_infos=[ENGLISH_TRACK]),
            str(ENGLISH_TRACK["Url"]): VTT,
        }
    )

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert len(evidence.transcript) == 1
    segment = evidence.transcript[0]
    assert "two cans of chickpeas" in segment.text
    assert segment.start_seconds == 0.04
    assert segment.end_seconds == 6.1
    # TikTok's tracks are machine transcription, and the contract must say so.
    assert segment.generated is True
    # Provenance names TikTok, not yt-dlp: this track is TikTok's own ASR.
    assert segment.provenance == "tiktok:asr:auto:eng-US"
    assert evidence.language == "eng-US"


def test_non_english_tracks_are_ignored() -> None:
    spanish = {**ENGLISH_TRACK, "LanguageCodeName": "spa-ES"}
    fetcher = Fetcher({VIDEO_URL: page(subtitle_infos=[spanish])})

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert evidence.transcript == []
    assert fetcher.urls == [VIDEO_URL]


def test_sticker_text_becomes_untimed_visual_evidence() -> None:
    fetcher = Fetcher(
        {
            VIDEO_URL: page(
                stickers=[
                    {"stickerText": ["Feta and Spinach Rice Paper Rolls \n(Air Fryer)"]}
                ]
            )
        }
    )

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert len(evidence.stickers) == 1
    sticker = evidence.stickers[0]
    assert sticker.provenance == "tiktok:sticker"
    # No fabricated timestamp: TikTok gives no time for sticker overlays.
    assert sticker.timestamp_seconds is None
    assert evidence.title == "Feta and Spinach Rice Paper Rolls (Air Fryer)"


def test_missing_blob_is_survivable() -> None:
    fetcher = Fetcher({VIDEO_URL: "<html>no data here</html>"})

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert evidence.is_empty


def test_unreachable_page_is_survivable() -> None:
    evidence = TikTokPageClient(fetcher=Fetcher({})).evidence(VIDEO_URL)

    assert evidence.is_empty


def test_caption_url_that_is_not_vtt_is_rejected() -> None:
    fetcher = Fetcher(
        {
            VIDEO_URL: page(subtitle_infos=[ENGLISH_TRACK]),
            str(ENGLISH_TRACK["Url"]): "<html>login wall</html>",
        }
    )

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert evidence.transcript == []


PHOTO_URL = "https://www.tiktok.com/@creator/photo/7481234567890123456"
PHOTO_STRUCT_URL = "https://www.tiktok.com/@creator/video/7481234567890123456"


def test_photo_post_struct_is_read_from_the_video_form_of_the_url() -> None:
    # The /photo/ page carries no rehydration blob at all; the identical item
    # is served at /video/<id>, imagePost included.
    fetcher = Fetcher(
        {
            PHOTO_STRUCT_URL: page(
                image_post={"title": "Hot Honey Garlic Chicken Tacos", "images": [{}]},
                description="2 cups flour. Mix and bake.",
            )
        }
    )

    evidence = TikTokPageClient(fetcher=fetcher).evidence(PHOTO_URL)

    assert fetcher.urls == [PHOTO_STRUCT_URL]
    assert evidence.media_kind is MediaKind.PHOTO
    assert evidence.metadata is not None
    assert evidence.metadata.description == "2 cups flour. Mix and bake."


def test_photo_post_title_comes_from_the_image_post() -> None:
    fetcher = Fetcher(
        {PHOTO_STRUCT_URL: page(image_post={"title": "Creamy Raisin Rice Pudding"})}
    )

    evidence = TikTokPageClient(fetcher=fetcher).evidence(PHOTO_URL)

    # Carousels rarely carry stickers, and imagePost.title is a real dish name
    # where the caption's first line is a hook.
    assert evidence.title == "Creamy Raisin Rice Pudding"


def test_sticker_title_still_wins_over_the_image_post_title() -> None:
    fetcher = Fetcher(
        {
            PHOTO_STRUCT_URL: page(
                image_post={"title": "a generic upload name"},
                stickers=[{"stickerText": ["Feta Rice Paper Rolls"]}],
            )
        }
    )

    assert (
        TikTokPageClient(fetcher=fetcher).evidence(PHOTO_URL).title
        == "Feta Rice Paper Rolls"
    )


def test_a_video_post_is_never_reported_as_a_photo_post() -> None:
    fetcher = Fetcher({VIDEO_URL: page(description="Add 2 cups flour.")})

    evidence = TikTokPageClient(fetcher=fetcher).evidence(VIDEO_URL)

    assert evidence.media_kind is MediaKind.VIDEO
    assert fetcher.urls == [VIDEO_URL]
