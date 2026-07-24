from dataclasses import dataclass, field
from uuid import UUID

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)


@dataclass
class FakeAcquirer:
    calls: list[SourceVideoDescriptor] = field(default_factory=list)

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        del job_id
        self.calls.append(source)
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title="Lemon Orzo",
            description="A fast one-pot recipe.",
            creator_name="Ladle Test Kitchen",
            language="en",
            transcript=[
                TextEvidence(
                    text="Add two cups orzo, then simmer for ten minutes.",
                    start_seconds=0,
                    end_seconds=6,
                    provenance="fake-native-caption",
                    generated=False,
                )
            ],
            visual_observations=[],
            diagnostics=[],
        )
