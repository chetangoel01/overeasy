import logging
from collections.abc import Callable, Mapping
from time import perf_counter
from typing import Protocol, TypeVar
from uuid import UUID

from ladle.acquisition.coverage import assess_coverage
from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
    ProviderUnavailable,
    TranscriptUnavailable,
)
from ladle.acquisition.free.acquirer import FreeAcquirer, FreeContext
from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    MediaMetadata,
    SourceCounts,
    SourceVideoDescriptor,
    TranscriptResult,
    VisualEvidence,
)
from ladle.acquisition.search import SparseTextEnricher
from ladle.observability.metrics import MetricsRegistry
from ladle.observability.structured_logging import log_context
from ladle.usage.circuit import CircuitBreaker, CircuitOpen

_T = TypeVar("_T")
LOGGER = logging.getLogger(__name__)
_PLATFORM_TEXT_PROVENANCES = {"instagram:altText", "tiktok:sticker"}


class PrimaryProvider(Protocol):
    def metadata(
        self, source: SourceVideoDescriptor, *, job_id: UUID
    ) -> MediaMetadata: ...

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        mode: str,
    ) -> TranscriptResult: ...


class TranscriptFallback(Protocol):
    def transcript(
        self, source: SourceVideoDescriptor, *, job_id: UUID
    ) -> TranscriptResult: ...


class AudioTranscriber(Protocol):
    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        media_url: str | None = None,
        media_headers: Mapping[str, str] | None = None,
        duration_seconds: float | None = None,
    ) -> TranscriptResult: ...


class ContextFallback(Protocol):
    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext: ...


class ProviderChain:
    def __init__(
        self,
        *,
        primary: PrimaryProvider | None,
        fallback: TranscriptFallback | None,
        circuits: CircuitBreaker | None = None,
        server_fallback: ContextFallback | None = None,
        free: FreeAcquirer | None = None,
        audio: AudioTranscriber | None = None,
        search: SparseTextEnricher | None = None,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._primary = primary
        self._fallback = fallback
        self._audio = audio
        self._search = search
        self._circuits = circuits
        self._server_fallback = server_fallback
        self._free = free
        self._metrics = metrics

    def check_public(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> bool:
        if self._free is not None:
            try:
                free = self._free.acquire(source, job_id=job_id)
            except PrivateOrDeleted:
                return False
            if free.has_metadata:
                return True
        if self._primary is None:
            return True
        primary = self._primary
        try:
            self._provider_call(
                "supadata",
                lambda: primary.metadata(source, job_id=job_id),
            )
        except PrivateOrDeleted:
            return False
        return True

    def refresh_counts(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> SourceCounts:
        """Free path only: the counts come from yt-dlp, and a refresh is not
        worth spending paid provider budget on."""
        del job_id
        if self._free is None:
            return SourceCounts()
        try:
            return self._free.counts(source)
        except Exception:
            LOGGER.info("Count refresh failed for %s", source.canonical_url)
            return SourceCounts()

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        diagnostics: list[str] = []
        free = self._free_context(source, job_id=job_id, diagnostics=diagnostics)
        documents = free.linked_documents

        metadata = free.metadata
        if metadata is None and self._primary is not None:
            primary = self._primary
            try:
                metadata = self._provider_call(
                    "supadata",
                    lambda: primary.metadata(source, job_id=job_id),
                )
            except PrivateOrDeleted:
                raise
            except (CircuitOpen, ProviderUnavailable):
                metadata = MediaMetadata(description="")
                diagnostics.append("metadataUnavailable")
        if metadata is None:
            metadata = MediaMetadata(description="")
            diagnostics.append("metadataUnavailable")

        transcript: TranscriptResult | None = None
        if free.transcript:
            transcript = TranscriptResult(
                segments=free.transcript,
                language=free.language,
            )
        # These are platform page fields, not text inferred from pixels.
        platform_text = [
            value
            for value in free.visual_observations
            if value.provenance in _PLATFORM_TEXT_PROVENANCES
        ]
        context = self._context(
            source,
            metadata=metadata,
            transcript=transcript,
            observations=platform_text,
            documents=documents,
            diagnostics=diagnostics,
        )
        # When the free rung already answered the question, no provider is
        # billed. A caption alone does not answer it: transcription is the
        # feature, and a fraction of a cent is the wrong thing to save when the
        # alternative is a recipe assembled from a promo blurb.
        free_coverage = assess_coverage(context)
        if free_coverage.sufficient_without_transcription:
            return context

        # Whisper on the raw audio undercuts the transcript providers by an
        # order of magnitude, so it goes first among the paid rungs.
        if transcript is None:
            transcript = self._audio_transcript(
                source,
                job_id=job_id,
                metadata=metadata,
                media_url=free.audio_url or free.media_url,
                media_headers=free.audio_headers,
                diagnostics=diagnostics,
            )
            if transcript is not None:
                context = self._context(
                    source,
                    metadata=metadata,
                    transcript=transcript,
                    observations=platform_text,
                    documents=documents,
                    diagnostics=diagnostics,
                )
                if assess_coverage(context).has_recipe_evidence:
                    return context

        if transcript is None and self._primary is not None:
            transcript = self._transcript_or_none(
                source,
                job_id=job_id,
                mode="auto",
                diagnostic="supadataTranscriptUnavailable",
                diagnostics=diagnostics,
            )
        if transcript is None and self._fallback is not None:
            fallback = self._fallback
            try:
                transcript = self._provider_call(
                    "soscripted",
                    lambda: fallback.transcript(
                        source,
                        job_id=job_id,
                    ),
                )
            except PrivateOrDeleted:
                raise
            except ProviderUnavailable:
                diagnostics.append("soscriptedUnavailable")

        result = self._context(
            source,
            metadata=metadata,
            transcript=transcript,
            observations=platform_text,
            documents=documents,
            diagnostics=diagnostics,
        )
        if (
            not assess_coverage(result).has_recipe_evidence
            and self._server_fallback is not None
        ):
            try:
                server = self._server_fallback.acquire(source, job_id=job_id)
            except ProviderUnavailable:
                result.diagnostics.append("serverFallbackUnavailable")
            else:
                result.transcript.extend(server.transcript)
                result.linked_documents.extend(server.linked_documents)
                result.diagnostics.append("serverFallbackUsed")
        if not assess_coverage(result).has_recipe_evidence and self._search is not None:
            search = self._search
            try:
                documents = self._provider_call(
                    "openrouterSearch",
                    lambda: search.enrich(result, job_id=job_id),
                )
            except (CircuitOpen, ProviderUnavailable):
                result.diagnostics.append("creatorSearchUnavailable")
            else:
                result.linked_documents.extend(documents)
                result.diagnostics.append(
                    "creatorSearchUsed" if documents else "creatorSearchNoMatch"
                )
        return result

    def _free_context(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        diagnostics: list[str],
    ) -> FreeContext:
        if self._free is None:
            return FreeContext()
        try:
            free = self._free.acquire(source, job_id=job_id)
        except PrivateOrDeleted:
            raise
        except ProviderUnavailable:
            diagnostics.append("freeAcquirerUnavailable")
            return FreeContext()
        diagnostics.extend(free.diagnostics)
        self._record_provider("free", "success" if free.has_metadata else "failure")
        return free

    def _audio_transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        metadata: MediaMetadata,
        media_url: str | None,
        media_headers: Mapping[str, str] | None,
        diagnostics: list[str],
    ) -> TranscriptResult | None:
        if self._audio is None:
            return None
        try:
            result = self._provider_call(
                "whisper",
                lambda: self._audio.transcript(  # type: ignore[union-attr]
                    source,
                    job_id=job_id,
                    media_url=media_url,
                    media_headers=media_headers,
                    duration_seconds=metadata.duration_seconds,
                ),
            )
        except PrivateOrDeleted:
            raise
        except (CircuitOpen, TranscriptUnavailable, ProviderUnavailable):
            diagnostics.append("audioTranscriptionUnavailable")
            return None
        diagnostics.append("audioTranscriptionUsed")
        return result

    def _transcript_or_none(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        mode: str,
        diagnostic: str,
        diagnostics: list[str],
    ) -> TranscriptResult | None:
        if self._primary is None:
            return None
        primary = self._primary
        try:
            return self._provider_call(
                "supadata",
                lambda: primary.transcript(
                    source,
                    job_id=job_id,
                    mode=mode,
                ),
            )
        except PrivateOrDeleted:
            raise
        except (CircuitOpen, TranscriptUnavailable, ProviderUnavailable):
            diagnostics.append(diagnostic)
            return None

    def _provider_call(
        self,
        provider: str,
        operation: Callable[[], _T],
    ) -> _T:
        started = perf_counter()
        if self._circuits is not None:
            try:
                self._circuits.before_call(provider)
            except CircuitOpen:
                self._record_provider(provider, "circuitOpen")
                raise
        with log_context(provider=provider):
            try:
                result = operation()
            except ProviderUnavailable as error:
                if self._circuits is not None:
                    self._circuits.record_failure(provider, error)
                if isinstance(error, ProviderQuotaError):
                    outcome = "quota"
                elif isinstance(error, ProviderAuthenticationError):
                    outcome = "auth"
                elif isinstance(error, ProviderTransientError):
                    outcome = "timeout"
                else:
                    outcome = "failure"
                self._record_provider(provider, outcome)
                LOGGER.warning(
                    "Provider call failed",
                    extra={
                        "provider": provider,
                        "duration_ms": round(
                            (perf_counter() - started) * 1000,
                            3,
                        ),
                        "terminal_result": outcome,
                        "exception_type": type(error).__name__,
                    },
                )
                raise
        if self._circuits is not None:
            self._circuits.record_success(provider)
        self._record_provider(provider, "success")
        LOGGER.info(
            "Provider call completed",
            extra={
                "provider": provider,
                "duration_ms": round((perf_counter() - started) * 1000, 3),
                "terminal_result": "success",
            },
        )
        return result

    def _record_provider(self, provider: str, outcome: str) -> None:
        if self._metrics is not None:
            self._metrics.record_provider(provider, outcome)

    def _context(
        self,
        source: SourceVideoDescriptor,
        *,
        metadata: MediaMetadata,
        transcript: TranscriptResult | None,
        observations: list[VisualEvidence],
        documents: list[LinkedDocument],
        diagnostics: list[str],
    ) -> AcquiredVideoContext:
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title=metadata.title,
            description=metadata.description,
            creator_name=metadata.creator_name,
            thumbnail_url=metadata.thumbnail_url,
            counts=metadata.counts,
            language=transcript.language if transcript is not None else None,
            transcript=transcript.segments if transcript is not None else [],
            visual_observations=observations,
            linked_documents=documents,
            diagnostics=diagnostics,
        )
