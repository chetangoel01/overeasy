from typing import Protocol
from uuid import UUID

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor


class VideoAcquirer(Protocol):
    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext: ...
