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
    public_checks: list[UUID] = field(default_factory=list)
    failure: Exception | None = None
    is_public: bool = True
    thumbnail_url: str | None = None
    context: AcquiredVideoContext | None = None
    title: str = "Lemon Orzo"
    description: str = "A fast one-pot recipe."
    transcript_text: str | None = (
        "Add two cups orzo, then simmer for ten minutes."
    )

    def check_public(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> bool:
        del job_id
        self.public_checks.append(source.source_video_id)
        if self.failure is not None:
            raise self.failure
        return self.is_public

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        del job_id
        self.calls.append(source)
        if self.failure is not None:
            raise self.failure
        if self.context is not None:
            return self.context.model_copy(update={"source": source})
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title=self.title,
            description=self.description,
            creator_name="Ladle Test Kitchen",
            thumbnail_url=self.thumbnail_url,
            language="en",
            transcript=(
                [
                    TextEvidence(
                        text=self.transcript_text,
                        start_seconds=0,
                        end_seconds=6,
                        provenance="fake-native-caption",
                        generated=False,
                    )
                ]
                if self.transcript_text
                else []
            ),
            visual_observations=[],
            diagnostics=[],
        )
