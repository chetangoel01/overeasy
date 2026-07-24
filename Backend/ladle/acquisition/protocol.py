from typing import Protocol
from uuid import UUID

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor


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
