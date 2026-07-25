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
from ladle.acquisition.free.links import (
    LinkFetcher,
    UnsafeURL,
    caption_links,
    substack_candidates,
)
from ladle.acquisition.free.ytdlp import YtDlpClient
from ladle.acquisition.models import (
    LinkedDocument,
    MediaMetadata,
    SourceVideoDescriptor,
    TextEvidence,
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
    diagnostics: list[str] = field(default_factory=list)

    @property
    def has_metadata(self) -> bool:
        return self.metadata is not None


def _already_covered(context: FreeContext) -> bool:
    """Mirrors assess_coverage over just what the free rung holds so far."""
    metadata = context.metadata
    if metadata is None:
        return False
    text = " ".join(
        [
            metadata.title or "",
            metadata.description,
            *(segment.text for segment in context.transcript),
        ]
    )
    return has_quantities(text) and has_instructions(text)


class FreeAcquirer:
    def __init__(
        self,
        *,
        ytdlp: YtDlpClient,
        fetcher: LinkFetcher | None = None,
        follow_caption_links: bool = True,
        subtitles_enabled: bool = True,
    ) -> None:
        self._ytdlp = ytdlp
        self._fetcher = fetcher
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
        if not self._ytdlp.available:
            context.diagnostics.append("freeAcquirerUnavailable")
            return context
        try:
            media = self._ytdlp.metadata(source.canonical_url)
        except PrivateOrDeleted:
            raise
        except ProviderUnavailable as error:
            LOGGER.info(
                "Free metadata unavailable for %s: %s", source.canonical_url, error
            )
            context.diagnostics.append("freeMetadataUnavailable")
            return context
        context.metadata = media.metadata
        context.diagnostics.append("freeMetadataUsed")

        if self._subtitles_enabled:
            track = media.preferred_track()
            if track is None:
                context.diagnostics.append("freeCaptionsUnavailable")
            else:
                segments = self._ytdlp.subtitles(source.canonical_url, track=track)
                if segments:
                    context.transcript = segments
                    context.language = track.language
                    context.diagnostics.append(
                        "freeGeneratedCaptionsUsed"
                        if track.generated
                        else "freeCaptionsUsed"
                    )
                else:
                    context.diagnostics.append("freeCaptionsUnavailable")

        # Captions and description may already be enough. Fetching anyway would
        # chase sponsor links through redirects for nothing.
        if _already_covered(context):
            context.diagnostics.append("freeCoverageSatisfied")
            return context

        if self._follow_caption_links and self._fetcher is not None:
            context.linked_documents = self._documents(
                media.metadata,
                diagnostics=context.diagnostics,
            )
        return context

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
