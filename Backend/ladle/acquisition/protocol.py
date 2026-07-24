from typing import Protocol

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor


class VideoAcquirer(Protocol):
    def acquire(self, source: SourceVideoDescriptor) -> AcquiredVideoContext: ...
