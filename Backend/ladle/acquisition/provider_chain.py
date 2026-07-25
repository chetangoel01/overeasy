from collections.abc import Callable
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
    SourceVideoDescriptor,
    TranscriptResult,
    VisualResult,
)
from ladle.observability.metrics import MetricsRegistry
from ladle.usage.circuit import CircuitBreaker, CircuitOpen

_T = TypeVar("_T")


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

    def visual(
        self, source: SourceVideoDescriptor, *, job_id: UUID
    ) -> VisualResult: ...


class TranscriptFallback(Protocol):
    def transcript(
        self, source: SourceVideoDescriptor, *, job_id: UUID
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
        primary: PrimaryProvider,
        fallback: TranscriptFallback,
        circuits: CircuitBreaker | None = None,
        server_fallback: ContextFallback | None = None,
        free: FreeAcquirer | None = None,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._primary = primary
        self._fallback = fallback
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
        try:
            self._provider_call(
                "supadata",
                lambda: self._primary.metadata(source, job_id=job_id),
            )
        except PrivateOrDeleted:
            return False
        return True

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
        if metadata is None:
            try:
                metadata = self._provider_call(
                    "supadata",
                    lambda: self._primary.metadata(source, job_id=job_id),
                )
            except PrivateOrDeleted:
                raise
            except (CircuitOpen, ProviderUnavailable):
                metadata = MediaMetadata(description="")
                diagnostics.append("metadataUnavailable")

        transcript: TranscriptResult | None = None
        if free.transcript:
            transcript = TranscriptResult(
                segments=free.transcript,
                language=free.language,
            )
        context = self._context(
            source,
            metadata=metadata,
            transcript=transcript,
            visual=None,
            documents=documents,
            diagnostics=diagnostics,
        )
        # When the free rung already answered the question, no provider is billed.
        if assess_coverage(context).sufficient_for_extraction:
            return context

        if transcript is None:
            transcript = self._transcript_or_none(
                source,
                job_id=job_id,
                mode="native",
                diagnostic="nativeTranscriptUnavailable",
                diagnostics=diagnostics,
            )
            context = self._context(
                source,
                metadata=metadata,
                transcript=transcript,
                visual=None,
                documents=documents,
                diagnostics=diagnostics,
            )
            if assess_coverage(context).sufficient_for_extraction:
                return context

        if transcript is None:
            transcript = self._transcript_or_none(
                source,
                job_id=job_id,
                mode="auto",
                diagnostic="supadataGeneratedUnavailable",
                diagnostics=diagnostics,
            )
            if transcript is None:
                try:
                    transcript = self._provider_call(
                        "soscripted",
                        lambda: self._fallback.transcript(
                            source,
                            job_id=job_id,
                        ),
                    )
                except PrivateOrDeleted:
                    raise
                except ProviderUnavailable:
                    diagnostics.append("soscriptedUnavailable")

        visual: VisualResult | None = None
        provisional = self._context(
            source,
            metadata=metadata,
            transcript=transcript,
            visual=None,
            documents=documents,
            diagnostics=diagnostics,
        )
        if not assess_coverage(provisional).sufficient_for_extraction:
            try:
                visual = self._provider_call(
                    "supadata",
                    lambda: self._primary.visual(source, job_id=job_id),
                )
            except PrivateOrDeleted:
                raise
            except (CircuitOpen, ProviderUnavailable):
                diagnostics.append("visualAnalysisUnavailable")

        result = self._context(
            source,
            metadata=metadata,
            transcript=transcript,
            visual=visual,
            documents=documents,
            diagnostics=diagnostics,
        )
        if (
            not assess_coverage(result).sufficient_for_extraction
            and self._server_fallback is not None
        ):
            try:
                server = self._server_fallback.acquire(source, job_id=job_id)
            except ProviderUnavailable:
                result.diagnostics.append("serverFallbackUnavailable")
            else:
                result.transcript.extend(server.transcript)
                result.visual_observations.extend(server.visual_observations)
                result.diagnostics.append("serverFallbackUsed")
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

    def _transcript_or_none(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        mode: str,
        diagnostic: str,
        diagnostics: list[str],
    ) -> TranscriptResult | None:
        try:
            return self._provider_call(
                "supadata",
                lambda: self._primary.transcript(
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
        if self._circuits is not None:
            try:
                self._circuits.before_call(provider)
            except CircuitOpen:
                self._record_provider(provider, "circuitOpen")
                raise
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
            raise
        if self._circuits is not None:
            self._circuits.record_success(provider)
        self._record_provider(provider, "success")
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
        visual: VisualResult | None,
        documents: list[LinkedDocument],
        diagnostics: list[str],
    ) -> AcquiredVideoContext:
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title=metadata.title,
            description=metadata.description,
            creator_name=metadata.creator_name,
            language=transcript.language if transcript is not None else None,
            transcript=transcript.segments if transcript is not None else [],
            visual_observations=(visual.observations if visual is not None else []),
            linked_documents=documents,
            diagnostics=diagnostics,
        )
