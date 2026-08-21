import json
import subprocess
from uuid import uuid4

from ladle.acquisition.free.acquirer import FreeAcquirer
from ladle.acquisition.free.tiktok import TikTokPageClient
from ladle.acquisition.free.ytdlp import YtDlpClient
from ladle.acquisition.models import SourceVideoDescriptor

COVERED_CAPTION = (
    "Add 2 cups of orzo and 400 g of chickpeas, then simmer for ten minutes."
)
THIN_CAPTION = "Recipe is on my site, link in bio"


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="tiktok",
        platform_video_id="v1",
        canonical_url="https://www.tiktok.com/@creator/video/1",
        source_revision="1",
    )


class Runner:
    def __init__(self, payload: dict[str, object]) -> None:
        self.payload = payload

    def __call__(
        self, command: list[str], *, timeout: float
    ) -> subprocess.CompletedProcess[str]:
        del command, timeout
        return subprocess.CompletedProcess(
            args=["yt-dlp"], returncode=0, stdout=json.dumps(self.payload), stderr=""
        )


class FailingRunner:
    def __call__(
        self, command: list[str], *, timeout: float
    ) -> subprocess.CompletedProcess[str]:
        del command, timeout
        return subprocess.CompletedProcess(
            args=["yt-dlp"],
            returncode=1,
            stdout="",
            stderr="Unexpected response from webpage request",
        )


class SpyFetcher:
    def __init__(self) -> None:
        self.urls: list[str] = []

    def fetch_text(self, url: str) -> str:
        self.urls.append(url)
        return "Add 200 g feta and bake until golden." * 10

    def fetch_raw(self, url: str) -> str:
        return self.fetch_text(url)


class ResponseFetcher:
    def __init__(self, responses: dict[str, str]) -> None:
        self.responses = responses

    def fetch_raw(self, url: str) -> str:
        return self.responses[url]

    def fetch_text(self, url: str) -> str:
        return self.fetch_raw(url)


def acquirer(description: str, fetcher: SpyFetcher) -> FreeAcquirer:
    payload = {"title": "Dinner", "description": description, "uploader": "creator"}
    return FreeAcquirer(
        ytdlp=YtDlpClient(binary="yt-dlp", runner=Runner(payload)),
        fetcher=fetcher,
        subtitles_enabled=False,
    )


def test_sufficient_caption_skips_link_fetching() -> None:
    fetcher = SpyFetcher()

    free = acquirer(
        f"{COVERED_CAPTION} more at https://sponsor.example.com/deal", fetcher
    )
    context = free.acquire(source(), job_id=uuid4())

    assert fetcher.urls == []
    assert "freeCoverageSatisfied" in context.diagnostics
    assert context.linked_documents == []


def test_thin_caption_follows_the_creators_own_link() -> None:
    fetcher = SpyFetcher()

    free = acquirer(f"{THIN_CAPTION} https://creator.example.com/recipe", fetcher)
    context = free.acquire(source(), job_id=uuid4())

    assert fetcher.urls == ["https://creator.example.com/recipe"]
    assert context.linked_documents[0].provenance == "captionLink"
    assert "freeCaptionLinkUsed" in context.diagnostics


def test_thin_caption_without_any_pointer_fetches_nothing() -> None:
    fetcher = SpyFetcher()

    free = acquirer("just a nice dinner", fetcher)
    context = free.acquire(source(), job_id=uuid4())

    assert fetcher.urls == []
    assert context.linked_documents == []


def test_a_covered_caption_still_fetches_the_creators_own_page() -> None:
    """Captions list ingredients; the creator's write-up states amounts.

    Justine's caption names soy sauce and gochujang with no quantity while
    justinesnacks.com gives both, and coverage being "satisfied" used to end
    acquisition before we ever looked.
    """

    fetcher = SpyFetcher()
    free = FreeAcquirer(
        ytdlp=YtDlpClient(
            binary="yt-dlp",
            runner=Runner(
                {
                    "title": "Gochujang Tofu",
                    "description": (
                        f"{COVERED_CAPTION} full recipe "
                        "https://justinesnacks.com/gochujang-tofu-mince"
                    ),
                    "uploader": "justine_snacks",
                }
            ),
        ),
        fetcher=fetcher,
        subtitles_enabled=False,
    )

    context = free.acquire(source(), job_id=uuid4())

    assert fetcher.urls == ["https://justinesnacks.com/gochujang-tofu-mince"]
    assert context.linked_documents[0].provenance == "captionLink"
    assert "freeCreatorPageUsed" in context.diagnostics


def test_a_covered_caption_still_ignores_a_sponsor_link() -> None:
    fetcher = SpyFetcher()
    free = acquirer(
        f"{COVERED_CAPTION} more at https://sponsor.example.com/deal", fetcher
    )

    context = free.acquire(source(), job_id=uuid4())

    assert fetcher.urls == []
    assert context.linked_documents == []


def test_tiktok_page_recovers_metadata_and_transcript_when_ytdlp_fails() -> None:
    video_url = source().canonical_url
    track_url = "https://cdn.tiktok.example/captions/eng.vtt"
    payload = {
        "__DEFAULT_SCOPE__": {
            "webapp.video-detail": {
                "itemInfo": {
                    "itemStruct": {
                        "desc": "Add 2 cups of rice and simmer until tender.",
                        "author": {"nickname": "Creator"},
                        "video": {
                            "cover": "https://images.example/recipe.jpg",
                            "duration": 30,
                            "subtitleInfos": [
                                {
                                    "Url": track_url,
                                    "Format": "webvtt",
                                    "LanguageCodeName": "eng-US",
                                    "Source": "ASR",
                                }
                            ],
                        },
                        "stickersOnItem": [],
                    }
                }
            }
        }
    }
    page = (
        '<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" '
        f'type="application/json">{json.dumps(payload)}</script>'
    )
    transcript = """WEBVTT

00:00:00.000 --> 00:00:04.000
Add the rice and simmer until tender.
"""
    page_fetcher = ResponseFetcher({video_url: page, track_url: transcript})
    free = FreeAcquirer(
        ytdlp=YtDlpClient(
            binary="yt-dlp",
            runner=FailingRunner(),
        ),
        tiktok=TikTokPageClient(fetcher=page_fetcher),
    )

    context = free.acquire(source(), job_id=uuid4())

    assert context.metadata is not None
    assert context.metadata.description.startswith("Add 2 cups")
    assert context.metadata.creator_name == "Creator"
    assert context.metadata.thumbnail_url == "https://images.example/recipe.jpg"
    assert context.transcript[0].text == "Add the rice and simmer until tender."
    assert "freeMetadataUnavailable" in context.diagnostics
    assert "tiktokPageMetadataUsed" in context.diagnostics
    assert "tiktokAsrCaptionsUsed" in context.diagnostics
