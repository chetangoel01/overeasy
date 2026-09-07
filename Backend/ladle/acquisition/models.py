import re
from datetime import datetime
from decimal import Decimal
from enum import StrEnum
from uuid import UUID

from pydantic import Field, model_validator

from ladle.contracts.common import WireModel
from ladle.db.models import SourceVideo


class MediaKind(StrEnum):
    """What the post is made of, which decides what can be read out of it.

    A photo post carries no audio and no video, so every transcript rung is a
    call that cannot succeed rather than a fallback that might. The caption is
    the whole text record.
    """

    VIDEO = "video"
    PHOTO = "photo"


#: TikTok publishes a carousel at /@user/photo/<id>; the same post is also
#: served at /video/<id>, so the path is the only thing that names the kind.
_TIKTOK_PHOTO_URL = re.compile(r"^https://[^/]+/@[^/]+/photo/[0-9]+/?$")


def media_kind_for_url(canonical_url: str) -> MediaKind:
    """The kind as the canonical URL states it.

    TikTok says it in the path, so a carousel is known before a single byte is
    fetched. Instagram does not — /p/ serves image carousels, video carousels
    and single videos from the same shape — so its kind is settled at fetch
    time by the embed blob instead, and this returns VIDEO until then.
    """

    return (
        MediaKind.PHOTO
        if _TIKTOK_PHOTO_URL.fullmatch(canonical_url)
        else MediaKind.VIDEO
    )


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

    @property
    def media_kind(self) -> MediaKind:
        """Derived, not stored: the canonical URL already carries the answer."""

        return media_kind_for_url(self.canonical_url)


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
    # On-screen text is not always timed: TikTok publishes sticker captions with
    # no time at all. Null says so rather than claiming it appeared at 0:00.
    timestamp_seconds: float | None = Field(default=None, ge=0)
    provenance: str = Field(min_length=1)
    confidence: float | None = Field(default=None, ge=0, le=1)


class LinkedDocument(WireModel):
    """A written page the creator themselves pointed at, fetched verbatim.

    Kept apart from transcript evidence because a blog post is not narration:
    conflating the two lets a model report a written method as something the
    creator said on camera.
    """

    url: str = Field(pattern=r"^https?://")
    text: str = Field(min_length=1, max_length=20_000)
    provenance: str = Field(min_length=1)


class SourceCounts(WireModel):
    """Engagement counts and publish date as the source platform reported them.

    A snapshot, not a live figure: it is whatever the platform said the last
    time we asked. Every field is optional because providers differ in what
    they return and any of them can be withheld for a given video.
    """

    like_count: int | None = Field(default=None, ge=0)
    view_count: int | None = Field(default=None, ge=0)
    comment_count: int | None = Field(default=None, ge=0)
    repost_count: int | None = Field(default=None, ge=0)
    published_at: datetime | None = None

    @property
    def is_empty(self) -> bool:
        return all(
            value is None
            for value in (
                self.like_count,
                self.view_count,
                self.comment_count,
                self.repost_count,
                self.published_at,
            )
        )


def apply_source_counts(
    source: SourceVideo,
    counts: SourceCounts,
    *,
    now: datetime,
) -> bool:
    """Write a counts snapshot onto the video, returning whether it changed.

    A provider that returns nothing leaves the previous snapshot alone rather
    than erasing it: a temporary failure should not look like a video losing
    all its likes. Individual fields follow the same rule.
    """
    if counts.is_empty:
        return False
    changed = False
    for field_name in (
        "like_count",
        "view_count",
        "comment_count",
        "repost_count",
        "published_at",
    ):
        value = getattr(counts, field_name)
        if value is None:
            continue
        if getattr(source, field_name) != value:
            setattr(source, field_name, value)
            changed = True
    source.counts_refreshed_at = now
    return changed


class MediaMetadata(WireModel):
    title: str | None = None
    description: str = Field(max_length=50_000)
    creator_name: str | None = None
    thumbnail_url: str | None = None
    duration_seconds: float | None = Field(default=None, ge=0)
    counts: SourceCounts = Field(default_factory=SourceCounts)
    billed_units: Decimal = Field(default=Decimal(0), ge=0)


class TranscriptResult(WireModel):
    segments: list[TextEvidence]
    language: str | None = None
    available_languages: list[str] = Field(default_factory=list)
    billed_units: Decimal = Field(default=Decimal(0), ge=0)
    cost_usd: Decimal | None = Field(default=None, ge=0)
    external_job_id: str | None = None


class AcquiredVideoContext(WireModel):
    source: SourceVideoDescriptor
    is_public: bool
    #: Photo posts have no narration to recover, so the caption in
    #: `description` is the whole text record and the failure when it carries
    #: no recipe is a different failure.
    media_kind: MediaKind = MediaKind.VIDEO
    title: str | None = None
    description: str = Field(max_length=50_000)
    creator_name: str | None = None
    thumbnail_url: str | None = None
    counts: SourceCounts = Field(default_factory=SourceCounts)
    language: str | None = None
    transcript: list[TextEvidence] = Field(default_factory=list)
    visual_observations: list[VisualEvidence] = Field(default_factory=list)
    linked_documents: list[LinkedDocument] = Field(default_factory=list)
    diagnostics: list[str] = Field(default_factory=list)
