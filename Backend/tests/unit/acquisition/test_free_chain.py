"""The free rung must actually displace paid calls, not merely precede them."""

from dataclasses import dataclass, field
from uuid import UUID, uuid4

import pytest

from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderUnavailable,
    TranscriptUnavailable,
)
from ladle.acquisition.free.acquirer import FreeContext
from ladle.acquisition.models import (
    LinkedDocument,
    MediaMetadata,
    SourceVideoDescriptor,
    TextEvidence,
    TranscriptResult,
    VisualResult,
)
from ladle.acquisition.provider_chain import ProviderChain


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="tiktok",
        platform_video_id="chickpeas",
        canonical_url="https://www.tiktok.com/@mishkamakesfood/video/1",
        source_revision="1",
    )


@dataclass
class Primary:
    calls: list[str] = field(default_factory=list)

    def metadata(self, source: SourceVideoDescriptor, *, job_id: UUID) -> MediaMetadata:
        del source, job_id
        self.calls.append("metadata")
        return MediaMetadata(description="paid description", billed_units=1)

    def transcript(
        self, source: SourceVideoDescriptor, *, job_id: UUID, mode: str
    ) -> TranscriptResult:
        del source, job_id
        self.calls.append(f"transcript:{mode}")
        raise TranscriptUnavailable()

    def visual(self, source: SourceVideoDescriptor, *, job_id: UUID) -> VisualResult:
        del source, job_id
        self.calls.append("visual")
        return VisualResult(observations=[], billed_units=1, external_job_id="v1")


@dataclass
class Fallback:
    calls: int = 0

    def transcript(
        self, source: SourceVideoDescriptor, *, job_id: UUID
    ) -> TranscriptResult:
        del source, job_id
        self.calls += 1
        # Mirrors SoScriptedClient, which signals an empty result this way.
        raise ProviderUnavailable("SoScripted returned no transcript")


@dataclass
class Free:
    context: FreeContext | Exception
    calls: int = 0

    def acquire(self, source: SourceVideoDescriptor, *, job_id: UUID) -> FreeContext:
        del source, job_id
        self.calls += 1
        if isinstance(self.context, Exception):
            raise self.context
        return self.context


def caption_only() -> FreeContext:
    return FreeContext(
        metadata=MediaMetadata(
            title="Creamy Garlic-Lemon Chickpeas",
            description=(
                "2 16oz cans of chickpeas, drained. 1 cup heavy cream (235ml). "
                "Simmer until thick, then stir through the lemon."
            ),
            creator_name="mishkamakesfood",
        ),
        diagnostics=["freeMetadataUsed"],
    )


def test_rich_caption_bills_nothing() -> None:
    primary = Primary()
    fallback = Fallback()
    free = Free(caption_only())
    chain = ProviderChain(primary=primary, fallback=fallback, free=free)

    context = chain.acquire(source(), job_id=uuid4())

    assert free.calls == 1
    assert primary.calls == []
    assert fallback.calls == 0
    assert context.creator_name == "mishkamakesfood"
    assert "freeMetadataUsed" in context.diagnostics


def test_free_captions_supply_timed_transcript_without_paid_calls() -> None:
    primary = Primary()
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Stuffed shells", description="A classic."),
            transcript=[
                TextEvidence(
                    text="Add 2 cups of ricotta and bake for 20 minutes.",
                    start_seconds=12.5,
                    end_seconds=30.0,
                    provenance="ytdlp:manual:en-US",
                    generated=False,
                )
            ],
            language="en-US",
            diagnostics=["freeMetadataUsed", "freeCaptionsUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free)

    context = chain.acquire(source(), job_id=uuid4())

    assert primary.calls == []
    assert context.language == "en-US"
    assert context.transcript[0].start_seconds == 12.5
    assert context.transcript[0].end_seconds == 30.0


def test_linked_document_alone_can_satisfy_coverage() -> None:
    primary = Primary()
    free = Free(
        FreeContext(
            metadata=MediaMetadata(
                title="Feta and Spinach Rice Paper Rolls",
                description="Recipe is on my site, link in bio",
                creator_name="shicocooks",
            ),
            linked_documents=[
                LinkedDocument(
                    url="https://shicocooks.com/rice-paper-rolls",
                    text="200 g feta, 2 cups spinach. Bake at 200C until golden.",
                    provenance="captionLink",
                )
            ],
            diagnostics=["freeMetadataUsed", "freeCaptionLinkUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free)

    context = chain.acquire(source(), job_id=uuid4())

    assert primary.calls == []
    assert context.linked_documents[0].provenance == "captionLink"


def test_thin_free_result_still_falls_through_to_paid_providers() -> None:
    primary = Primary()
    fallback = Fallback()
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Dinner", description="so good"),
            diagnostics=["freeMetadataUsed", "freeCaptionsUnavailable"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=fallback, free=free)

    context = chain.acquire(source(), job_id=uuid4())

    # Metadata came free, so only the transcript and visual rungs are billed.
    assert "metadata" not in primary.calls
    assert primary.calls == ["transcript:native", "transcript:auto", "visual"]
    assert fallback.calls == 1
    assert context.description == "so good"


def test_free_metadata_failure_falls_back_to_paid_metadata() -> None:
    primary = Primary()
    free = Free(FreeContext(diagnostics=["freeMetadataUnavailable"]))
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free)

    context = chain.acquire(source(), job_id=uuid4())

    assert primary.calls[0] == "metadata"
    assert context.description == "paid description"


def test_free_rung_deletion_signal_propagates() -> None:
    chain = ProviderChain(
        primary=Primary(), fallback=Fallback(), free=Free(PrivateOrDeleted("gone"))
    )

    with pytest.raises(PrivateOrDeleted):
        chain.acquire(source(), job_id=uuid4())


def test_check_public_uses_free_rung_before_billing() -> None:
    primary = Primary()
    free = Free(caption_only())
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free)

    assert chain.check_public(source(), job_id=uuid4()) is True
    assert primary.calls == []
