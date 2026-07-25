"""The free rung must actually displace paid calls, not merely precede them."""

from dataclasses import dataclass, field
from decimal import Decimal
from uuid import UUID, uuid4

import pytest

from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderUnavailable,
    TranscriptUnavailable,
    VisualAnalysisUnavailable,
)
from ladle.acquisition.free.acquirer import FreeContext
from ladle.acquisition.models import (
    LinkedDocument,
    MediaMetadata,
    SourceVideoDescriptor,
    TextEvidence,
    TranscriptResult,
    VisualEvidence,
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


def test_free_sticker_text_survives_into_the_paid_result() -> None:
    primary = Primary()
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Rice Paper Rolls", description="link in bio"),
            visual_observations=[
                VisualEvidence(
                    text="Feta and Spinach Rice Paper Rolls",
                    timestamp_seconds=None,
                    provenance="tiktok:sticker",
                )
            ],
            diagnostics=["freeMetadataUsed", "tiktokStickerTextUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free)

    context = chain.acquire(source(), job_id=uuid4())

    # The chain kept going to paid providers, but did not drop what was free.
    assert primary.calls == ["transcript:native", "transcript:auto", "visual"]
    assert [value.provenance for value in context.visual_observations] == [
        "tiktok:sticker"
    ]


def test_free_transcript_skips_every_paid_transcript_rung() -> None:
    primary = Primary()
    fallback = Fallback()
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Chickpeas", description="link in bio"),
            transcript=[
                TextEvidence(
                    text="I'm making recipes for real life.",
                    start_seconds=0.04,
                    end_seconds=3.24,
                    provenance="tiktok:asr:auto:eng-US",
                    generated=True,
                )
            ],
            language="eng-US",
            diagnostics=["tiktokAsrCaptionsUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=fallback, free=free)

    chain.acquire(source(), job_id=uuid4())

    # TikTok's ASR covers the same audio Supadata would bill for, so only the
    # visual rung is worth paying for after it.
    assert primary.calls == ["visual"]
    assert fallback.calls == 0


@dataclass
class Audio:
    result: TranscriptResult | Exception
    calls: list[tuple[str | None, float | None]] = field(default_factory=list)

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        media_url: str | None = None,
        duration_seconds: float | None = None,
    ) -> TranscriptResult:
        del source, job_id
        self.calls.append((media_url, duration_seconds))
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def whisper_transcript() -> TranscriptResult:
    return TranscriptResult(
        segments=[
            TextEvidence(
                text="Add 2 cans of chickpeas, then simmer until it thickens.",
                start_seconds=0.28,
                end_seconds=12.0,
                provenance="whisper:openai/whisper-large-v3",
                generated=True,
            )
        ],
        language="english",
        billed_units=Decimal("22.3"),
    )


def test_a_rich_caption_does_not_excuse_us_from_listening() -> None:
    """Transcription is the product, not an expense to dodge.

    A caption that names amounts and a cooking verb used to end acquisition
    outright, so any video whose creator wrote a decent blurb was never heard
    at all — losing the technique, timing and substitutions they only say out
    loud. Whisper costs a fraction of a cent; the caption is not a substitute.
    """

    primary = Primary()
    audio = Audio(whisper_transcript())
    free = Free(caption_only())
    chain = ProviderChain(primary=primary, fallback=Fallback(), free=free, audio=audio)

    context = chain.acquire(source(), job_id=uuid4())

    assert len(audio.calls) == 1
    assert "audioTranscriptionUsed" in context.diagnostics
    assert context.transcript[0].provenance == "whisper:openai/whisper-large-v3"
    # Still nothing billed to the transcript providers.
    assert primary.calls == []


def test_an_unheard_video_with_a_rich_caption_still_bills_nothing() -> None:
    """Listening is worth attempting; buying what we can already read is not."""

    primary = Primary()
    fallback = Fallback()
    audio = Audio(TranscriptUnavailable("no audio stream"))
    chain = ProviderChain(
        primary=primary,
        fallback=fallback,
        free=Free(caption_only()),
        audio=audio,
    )

    context = chain.acquire(source(), job_id=uuid4())

    assert len(audio.calls) == 1
    assert primary.calls == []
    assert fallback.calls == 0
    assert "audioTranscriptionUnavailable" in context.diagnostics


@dataclass
class Vision:
    result: VisualResult | Exception
    calls: int = 0

    def visual(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        media_url: str | None = None,
        duration_seconds: float | None = None,
    ) -> VisualResult:
        del source, job_id, media_url, duration_seconds
        self.calls += 1
        if isinstance(self.result, Exception):
            raise self.result
        return self.result


def seen_cooking() -> VisualResult:
    return VisualResult(
        observations=[
            VisualEvidence(
                text="Feta and spinach are spooned onto a rice paper sheet.",
                timestamp_seconds=12.0,
                provenance="vision:google/gemini-2.5-flash",
            )
        ],
        billed_units=Decimal(1),
        external_job_id="vision:visual:1",
    )


def test_watching_the_video_comes_before_paying_to_have_it_watched() -> None:
    """Frames we sample ourselves undercut the visual provider they precede."""

    primary = Primary()
    vision = Vision(seen_cooking())
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Rice Paper Rolls", description="link in bio"),
            diagnostics=["freeMetadataUsed"],
        )
    )
    chain = ProviderChain(
        primary=primary, fallback=Fallback(), free=free, vision=vision
    )

    context = chain.acquire(source(), job_id=uuid4())

    assert vision.calls == 1
    assert "visual" not in primary.calls
    assert "frameAnalysisUsed" in context.diagnostics
    assert context.visual_observations[0].timestamp_seconds == 12.0


def test_unwatchable_video_still_falls_through_to_the_visual_provider() -> None:
    primary = Primary()
    vision = Vision(VisualAnalysisUnavailable("no media"))
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Dinner", description="so good"),
            diagnostics=["freeMetadataUsed"],
        )
    )
    chain = ProviderChain(
        primary=primary, fallback=Fallback(), free=free, vision=vision
    )

    context = chain.acquire(source(), job_id=uuid4())

    assert vision.calls == 1
    assert "visual" in primary.calls
    assert "frameAnalysisUnavailable" in context.diagnostics


def test_a_covered_recipe_is_never_watched() -> None:
    """Nothing to gain from frames when the evidence already answers."""

    vision = Vision(seen_cooking())
    chain = ProviderChain(
        primary=Primary(),
        fallback=Fallback(),
        free=Free(caption_only()),
        vision=vision,
    )

    chain.acquire(source(), job_id=uuid4())

    assert vision.calls == 0


def test_audio_transcription_runs_before_the_transcript_providers() -> None:
    primary = Primary()
    fallback = Fallback()
    audio = Audio(whisper_transcript())
    free = Free(
        FreeContext(
            metadata=MediaMetadata(
                title="Chickpeas",
                description="link in bio",
                duration_seconds=22.3,
            ),
            media_url="https://cdn.instagram.com/reel.mp4",
            diagnostics=["instagramEmbedUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=fallback, free=free, audio=audio)

    context = chain.acquire(source(), job_id=uuid4())

    # Whisper answered, so neither Supadata transcript rung nor SoScripted ran.
    assert audio.calls == [("https://cdn.instagram.com/reel.mp4", 22.3)]
    assert primary.calls == []
    assert fallback.calls == 0
    assert context.transcript[0].provenance == "whisper:openai/whisper-large-v3"
    assert "audioTranscriptionUsed" in context.diagnostics


def test_failed_transcription_still_falls_through_to_paid_providers() -> None:
    primary = Primary()
    fallback = Fallback()
    audio = Audio(TranscriptUnavailable("no audio"))
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Dinner", description="so good"),
            diagnostics=["freeMetadataUsed"],
        )
    )
    chain = ProviderChain(primary=primary, fallback=fallback, free=free, audio=audio)

    context = chain.acquire(source(), job_id=uuid4())

    assert len(audio.calls) == 1
    assert primary.calls == ["transcript:native", "transcript:auto", "visual"]
    assert fallback.calls == 1
    assert "audioTranscriptionUnavailable" in context.diagnostics


def test_free_transcript_means_no_transcription_is_bought() -> None:
    audio = Audio(whisper_transcript())
    free = Free(
        FreeContext(
            metadata=MediaMetadata(title="Chickpeas", description="link in bio"),
            transcript=[
                TextEvidence(
                    text="Add 2 cups of orzo and simmer for ten minutes.",
                    start_seconds=0,
                    end_seconds=5,
                    provenance="tiktok:asr:auto:eng-US",
                    generated=True,
                )
            ],
            diagnostics=["tiktokAsrCaptionsUsed"],
        )
    )
    chain = ProviderChain(
        primary=Primary(), fallback=Fallback(), free=free, audio=audio
    )

    chain.acquire(source(), job_id=uuid4())

    assert audio.calls == []


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
