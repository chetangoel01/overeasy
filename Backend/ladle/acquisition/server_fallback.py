from typing import Protocol
from uuid import UUID

from ladle.acquisition.errors import ProviderUnavailable
from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor


class ServerMediaProcessor(Protocol):
    """Injected server-only media pipeline that owns and deletes temp media."""

    def process(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext: ...


class ServerFallbackAdapter:
    def __init__(
        self,
        *,
        enabled: bool,
        processor: ServerMediaProcessor | None = None,
    ) -> None:
        self._enabled = enabled
        self._processor = processor

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        if not self._enabled or self._processor is None:
            raise ProviderUnavailable("server media fallback is disabled")
        return self._processor.process(source, job_id=job_id)
