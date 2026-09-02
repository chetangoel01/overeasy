from typing import Protocol
from uuid import UUID

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceCounts,
    SourceVideoDescriptor,
)


class VideoAcquirer(Protocol):
    def check_public(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> bool: ...

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext: ...

    def refresh_counts(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> SourceCounts:
        """Re-read engagement counts without acquiring media.

        Called when an import lands on an already-cached video, which is the
        only moment the app re-reads a source it already has. Implementations
        must be cheap and must not raise: a failed refresh leaves the previous
        snapshot in place.
        """
        ...
