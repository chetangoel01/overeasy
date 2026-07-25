import json
import subprocess
from uuid import uuid4

from ladle.acquisition.free.acquirer import FreeAcquirer
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


class SpyFetcher:
    def __init__(self) -> None:
        self.urls: list[str] = []

    def fetch_text(self, url: str) -> str:
        self.urls.append(url)
        return "Add 200 g feta and bake until golden." * 10

    def fetch_raw(self, url: str) -> str:
        return self.fetch_text(url)


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
