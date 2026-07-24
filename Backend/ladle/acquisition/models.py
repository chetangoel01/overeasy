from uuid import UUID

from pydantic import Field, model_validator

from ladle.contracts.common import WireModel
from ladle.db.models import SourceVideo


class SourceVideoDescriptor(WireModel):
    source_video_id: UUID
    platform: str = Field(pattern=r"^(youtube|tiktok|instagram)$")
    platform_video_id: str = Field(min_length=1)
    canonical_url: str = Field(pattern=r"^https://")
    source_revision: str = Field(min_length=1)

    @classmethod
    def from_stored(cls, source: SourceVideo) -> "SourceVideoDescriptor":
        return cls(
            source_video_id=source.id,
            platform=source.platform,
            platform_video_id=source.platform_video_id,
            canonical_url=source.canonical_url,
            source_revision=source.source_revision,
        )


class TextEvidence(WireModel):
    text: str = Field(min_length=1, max_length=20_000)
    start_seconds: float | None = Field(default=None, ge=0)
    end_seconds: float | None = Field(default=None, ge=0)
    provenance: str = Field(min_length=1)
    generated: bool

    @model_validator(mode="after")
    def validate_time_range(self) -> "TextEvidence":
        if (
            self.start_seconds is not None
            and self.end_seconds is not None
            and self.end_seconds < self.start_seconds
        ):
            raise ValueError("evidence end must not precede its start")
        return self


class VisualEvidence(WireModel):
    text: str = Field(min_length=1, max_length=20_000)
    timestamp_seconds: float = Field(ge=0)
    provenance: str = Field(min_length=1)
    confidence: float | None = Field(default=None, ge=0, le=1)


class AcquiredVideoContext(WireModel):
    source: SourceVideoDescriptor
    is_public: bool
    title: str | None = None
    description: str = Field(max_length=50_000)
    creator_name: str | None = None
    language: str | None = None
    transcript: list[TextEvidence] = Field(default_factory=list)
    visual_observations: list[VisualEvidence] = Field(default_factory=list)
    diagnostics: list[str] = Field(default_factory=list)
