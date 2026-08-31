"""The keyless first rung of the acquisition ladder.

Everything here is free: yt-dlp reads public metadata and captions, and pages
are fetched only when the creator themselves pointed at them. Billed providers
run afterwards, and only for whatever this rung could not supply.
"""

import logging
import re
from dataclasses import dataclass, field
from uuid import UUID

import httpx

from ladle.acquisition.coverage import has_instructions, has_quantities
from ladle.acquisition.errors import PrivateOrDeleted, ProviderUnavailable
from ladle.acquisition.free.instagram import InstagramEmbedClient
from ladle.acquisition.free.links import (
    LinkFetcher,
    UnsafeURL,
    belongs_to_creator,
    caption_links,
    substack_candidates,
)
from ladle.acquisition.free.tiktok import TikTokPageClient
from ladle.acquisition.free.ytdlp import YtDlpClient
from ladle.acquisition.models import (
    LinkedDocument,
    MediaMetadata,
    SourceCounts,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)

LOGGER = logging.getLogger(__name__)

_RECIPE_ELSEWHERE = re.compile(
    r"link in (my )?bio|full (written )?recipe|recipes? (is |are )?(in|on|at) my|"
    r"all my recipes|link below|recipe on my",
    re.IGNORECASE,
)
_MINIMUM_DOCUMENT_CHARACTERS = 200


@dataclass
class FreeContext:
    """What the free rung managed to gather. Any field may be empty."""

    metadata: MediaMetadata | None = None
    transcript: list[TextEvidence] = field(default_factory=list)
    language: str | None = None
    linked_documents: list[LinkedDocument] = field(default_factory=list)
    visual_observations: list[VisualEvidence] = field(default_factory=list)
    media_url: str | None = None
    audio_url: str | None = None
    audio_headers: dict[str, str] = field(default_factory=dict, repr=False)
    video_url: str | None = None
    diagnostics: list[str] = field(default_factory=list)

    @property
    def has_metadata(self) -> bool:
        return self.metadata is not None


def _already_covered(context: FreeContext) -> bool:
    """Mirrors assess_coverage over just what the free rung holds so far.

    This governs only whether to chase links out of the caption. A caption
    carrying the whole recipe really is enough text to stop fetching more of
    it — unlike the decision to transcribe, which the caption cannot answer
    because narration is evidence a caption does not contain.
    """

    metadata = context.metadata
    if metadata is None:
        return False
    text = " ".join(
        [
            metadata.title or "",
            metadata.description,
            *(segment.text for segment in context.transcript),
            *(value.text for value in context.visual_observations),
        ]
    )
    return has_quantities(text) and has_instructions(text)


class FreeAcquirer:
    def __init__(
        self,
        *,
        ytdlp: YtDlpClient,
        fetcher: LinkFetcher | None = None,
        tiktok: TikTokPageClient | None = None,
        instagram: InstagramEmbedClient | None = None,
        follow_caption_links: bool = True,
        subtitles_enabled: bool = True,
    ) -> None:
        self._ytdlp = ytdlp
        self._fetcher = fetcher
        self._tiktok = tiktok
        self._instagram = instagram
        self._follow_caption_links = follow_caption_links
        self._subtitles_enabled = subtitles_enabled

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> FreeContext:
        del job_id
        context = FreeContext()

        # Instagram refuses yt-dlp without browser cookies, so its embed
        # endpoint is the primary source there rather than a fallback.
        if source.platform == "instagram":
            self._apply_instagram_embed(source, context)
        if not context.has_metadata:
            self._apply_ytdlp(source, context)

        # yt-dlp reports nothing for TikTok, but TikTok publishes its own ASR
        # track in the page. Worth a look whenever captions are still missing.
        if not context.transcript and source.platform == "tiktok":
            self._apply_tiktok_page(source.canonical_url, context)
        metadata = context.metadata
        if metadata is None:
            return context

        # Captions and description may already be enough. Fetching anyway would
        # chase sponsor links through redirects for nothing.
        if _already_covered(context):
            context.diagnostics.append("freeCoverageSatisfied")
            # One exception to stopping here: a page on the creator's own
            # domain. A caption that lists ingredients still rounds the
            # amounts off — "soy sauce" with no quantity — where their own
            # write-up states them. Sponsor links stay unfetched.
            context.linked_documents = self._creator_documents(
                metadata,
                diagnostics=context.diagnostics,
            )
            return context

        if self._follow_caption_links and self._fetcher is not None:
            context.linked_documents = self._documents(
                metadata,
                diagnostics=context.diagnostics,
            )
        return context

    def counts(self, source: SourceVideoDescriptor) -> SourceCounts:
        """Engagement counts alone, without downloading any media.

        This is the refresh path: it runs when someone imports a video that is
        already cached, so it must stay a single metadata call.
        """
        if not self._ytdlp.available:
            return SourceCounts()
        try:
            return self._ytdlp.metadata(source.canonical_url).metadata.counts
        except (PrivateOrDeleted, ProviderUnavailable):
            return SourceCounts()

    def _apply_ytdlp(
        self,
        source: SourceVideoDescriptor,
        context: FreeContext,
    ) -> None:
        if not self._ytdlp.available:
            context.diagnostics.append("freeAcquirerUnavailable")
            return
        try:
            media = self._ytdlp.metadata(source.canonical_url)
        except PrivateOrDeleted:
            raise
        except ProviderUnavailable as error:
            LOGGER.info(
                "Free metadata unavailable for %s: %s", source.canonical_url, error
            )
            context.diagnostics.append("freeMetadataUnavailable")
            return
        context.metadata = media.metadata
        context.media_url = media.media_url
        context.audio_url = media.audio_url or media.media_url
        context.audio_headers = (
            media.audio_headers if media.audio_url else media.media_headers
        )
        context.video_url = media.video_url or media.media_url
        context.diagnostics.append("freeMetadataUsed")

        if not self._subtitles_enabled:
            return
        track = media.preferred_track()
        if track is None:
            context.diagnostics.append("freeCaptionsUnavailable")
            return
        segments = self._ytdlp.subtitles(source.canonical_url, track=track)
        if not segments:
            context.diagnostics.append("freeCaptionsUnavailable")
            return
        context.transcript = segments
        context.language = track.language
        context.diagnostics.append(
            "freeGeneratedCaptionsUsed" if track.generated else "freeCaptionsUsed"
        )

    def _apply_instagram_embed(
        self,
        source: SourceVideoDescriptor,
        context: FreeContext,
    ) -> None:
        if self._instagram is None:
            return
        media = self._instagram.metadata(source)
        if media is None:
            context.diagnostics.append("instagramEmbedUnavailable")
            return
        context.metadata = media.metadata
        context.visual_observations = media.observations
        context.media_url = media.media_url
        context.audio_url = media.media_url
        context.video_url = media.media_url
        context.diagnostics.append("instagramEmbedUsed")

    def _apply_tiktok_page(self, canonical_url: str, context: FreeContext) -> None:
        if self._tiktok is None or not self._subtitles_enabled:
            return
        evidence = self._tiktok.evidence(canonical_url)
        if evidence.is_empty:
            context.diagnostics.append("tiktokPageEvidenceUnavailable")
            return
        if evidence.metadata is not None:
            page = evidence.metadata
            metadata = context.metadata
            if metadata is None:
                context.metadata = page
            else:
                metadata.description = metadata.description or page.description
                metadata.creator_name = metadata.creator_name or page.creator_name
                metadata.thumbnail_url = metadata.thumbnail_url or page.thumbnail_url
                metadata.duration_seconds = (
                    metadata.duration_seconds or page.duration_seconds
                )
            context.diagnostics.append("tiktokPageMetadataUsed")
        if evidence.transcript:
            context.transcript = evidence.transcript
            context.language = evidence.language
            context.diagnostics.append("tiktokAsrCaptionsUsed")
        if evidence.stickers:
            context.visual_observations = evidence.stickers
            context.diagnostics.append("tiktokStickerTextUsed")
        metadata = context.metadata
        # A TikTok title is the caption's opening promo line; the on-screen
        # sticker is what the creator actually called the dish.
        if metadata is not None and evidence.title:
            metadata.title = evidence.title

    def _creator_documents(
        self,
        metadata: MediaMetadata,
        *,
        diagnostics: list[str],
    ) -> list[LinkedDocument]:
        """Only pages on the creator's own domain, for the covered case."""

        if not self._follow_caption_links or self._fetcher is None:
            return []
        owned = [
            url
            for url in caption_links(metadata.description)
            if belongs_to_creator(url, metadata.creator_name)
        ]
        if not owned:
            return []
        documents = self._fetch_all(owned, provenance="captionLink")
        if documents:
            diagnostics.append("freeCreatorPageUsed")
        return documents

    def _documents(
        self,
        metadata: MediaMetadata,
        *,
        diagnostics: list[str],
    ) -> list[LinkedDocument]:
        assert self._fetcher is not None
        documents = self._fetch_all(
            caption_links(metadata.description),
            provenance="captionLink",
        )
        if documents:
            diagnostics.append("freeCaptionLinkUsed")
            return documents
        # "Link in bio" posts carry no URL. The creator's own Substack is the one
        # place we can still reach without guessing at authorship.
        if not _RECIPE_ELSEWHERE.search(metadata.description or ""):
            return []
        candidates = substack_candidates(
            metadata.creator_name or "",
            metadata.title or "",
            fetcher=self._fetcher,
        )
        documents = self._fetch_all(candidates, provenance="creatorSubstack")
        if documents:
            diagnostics.append("freeCreatorPageUsed")
        else:
            diagnostics.append("freeCreatorPageUnavailable")
        return documents

    def _fetch_all(self, urls: list[str], *, provenance: str) -> list[LinkedDocument]:
        assert self._fetcher is not None
        documents: list[LinkedDocument] = []
        for url in urls[:2]:
            try:
                text = self._fetcher.fetch_text(url)
            except (UnsafeURL, OSError, httpx.HTTPError) as error:
                LOGGER.info("Linked page fetch refused for %s: %s", url, error)
                continue
            # A page must actually state amounts to stand in for the recipe;
            # a paywall teaser or a landing page must not.
            if len(text) < _MINIMUM_DOCUMENT_CHARACTERS or not has_quantities(text):
                continue
            documents.append(LinkedDocument(url=url, text=text, provenance=provenance))
        return documents
