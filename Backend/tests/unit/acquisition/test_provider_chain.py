from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderQuotaError,
    TranscriptUnavailable,
)
from ladle.acquisition.models import (
    MediaMetadata,
    SourceVideoDescriptor,
    TranscriptResult,
    VisualResult,
)
from ladle.acquisition.provider_chain import ProviderChain
from ladle.observability.metrics import MetricsRegistry
from ladle.usage.circuit import CircuitBreaker, CircuitOpen


def source() -> SourceVideoDescriptor:
    return SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="instagram",
        platform_video_id="recipe-reel",
        canonical_url="https://www.instagram.com/reel/recipe-reel",
        source_revision="1",
    )


@dataclass
class Primary:
    native: TranscriptResult | Exception
    generated: TranscriptResult | Exception
    visual_result: VisualResult | Exception
    calls: list[str] = field(default_factory=list)

    def metadata(self, source: SourceVideoDescriptor, *, job_id: UUID) -> MediaMetadata:
        del source, job_id
        self.calls.append("metadata")
        return MediaMetadata(
            title="Recipe",
            description="Add flour and bake.",
            creator_name="Creator",
            thumbnail_url=None,
            duration_seconds=30,
            billed_units=1,
        )

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        mode: str,
    ) -> TranscriptResult:
        del source, job_id
        self.calls.append(f"transcript:{mode}")
        value = self.native if mode == "native" else self.generated
        if isinstance(value, Exception):
            raise value
        return value

    def visual(self, source: SourceVideoDescriptor, *, job_id: UUID) -> VisualResult:
        del source, job_id
        self.calls.append("visual")
        if isinstance(self.visual_result, Exception):
            raise self.visual_result
        return self.visual_result


@dataclass
class Fallback:
    result: TranscriptResult
    calls: int = 0

    def transcript(
        self, source: SourceVideoDescriptor, *, job_id: UUID
    ) -> TranscriptResult:
        del source, job_id
        self.calls += 1
        return self.result


@dataclass
class ContextBackup:
    result: object
    calls: int = 0

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> object:
        del source, job_id
        self.calls += 1
        return self.result


def transcript(text: str, provenance: str = "supadata") -> TranscriptResult:
    from ladle.acquisition.models import TextEvidence

    return TranscriptResult(
        segments=[
            TextEvidence(
                text=text,
                start_seconds=0,
                end_seconds=5,
                provenance=provenance,
                generated=provenance != "supadata-native",
            )
        ],
        language="en",
        billed_units=1,
    )


def empty_visual() -> VisualResult:
    return VisualResult(observations=[], billed_units=0, external_job_id="visual-1")


def test_sufficient_native_material_skips_paid_fallbacks() -> None:
    primary = Primary(
        native=transcript(
            "Add 2 cups flour. Mix well, then bake for 20 minutes.",
            "supadata-native",
        ),
        generated=TranscriptUnavailable(),
        visual_result=empty_visual(),
    )
    fallback = Fallback(transcript("unused"))
    metrics = MetricsRegistry()
    chain = ProviderChain(
        primary=primary,
        fallback=fallback,
        metrics=metrics,
    )

    context = chain.acquire(source(), job_id=uuid4())

    assert context.transcript[0].provenance == "supadata-native"
    assert primary.calls == ["metadata", "transcript:native"]
    assert fallback.calls == 0
    assert (
        'ladle_provider_total{outcome="success",provider="supadata"} 2'
        in metrics.render()
    )


def test_public_recheck_uses_metadata_without_transcript_or_visual_spend() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=TranscriptUnavailable(),
        visual_result=empty_visual(),
    )
    chain = ProviderChain(
        primary=primary,
        fallback=Fallback(transcript("unused")),
    )

    assert chain.check_public(source(), job_id=uuid4())
    assert primary.calls == ["metadata"]


def test_quota_or_missing_native_uses_transcript_and_visual_backups() -> None:
    from ladle.acquisition.models import VisualEvidence

    primary = Primary(
        native=TranscriptUnavailable(),
        generated=ProviderQuotaError(),
        visual_result=VisualResult(
            observations=[
                VisualEvidence(
                    text="2 cups flour",
                    timestamp_seconds=1,
                    provenance="supadata-visual",
                    confidence=0.9,
                )
            ],
            billed_units=2,
            external_job_id="visual-1",
        ),
    )
    fallback = Fallback(
        transcript("Add flour. Mix well, then bake for 20 minutes.", "soscripted")
    )
    chain = ProviderChain(primary=primary, fallback=fallback)

    context = chain.acquire(source(), job_id=uuid4())

    assert fallback.calls == 1
    assert context.transcript[0].provenance == "soscripted"
    assert context.visual_observations[0].text == "2 cups flour"
    assert "supadataGeneratedUnavailable" in context.diagnostics


def test_private_source_short_circuits_all_fallback_spend() -> None:
    primary = Primary(
        native=PrivateOrDeleted(),
        generated=TranscriptUnavailable(),
        visual_result=empty_visual(),
    )
    fallback = Fallback(transcript("must not run"))
    chain = ProviderChain(primary=primary, fallback=fallback)

    with pytest.raises(PrivateOrDeleted):
        chain.acquire(source(), job_id=uuid4())

    assert fallback.calls == 0


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def test_quota_failure_opens_primary_circuit_and_uses_independent_backup() -> None:
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    circuits = CircuitBreaker(
        clock=clock,
        failure_threshold=3,
        cooldown=timedelta(minutes=10),
    )
    primary = Primary(
        native=ProviderQuotaError(),
        generated=transcript("must not run"),
        visual_result=empty_visual(),
    )
    fallback = Fallback(
        transcript(
            "Add 2 cups flour. Mix well, then bake for 20 minutes.",
            "soscripted",
        )
    )
    chain = ProviderChain(
        primary=primary,
        fallback=fallback,
        circuits=circuits,
    )

    result = chain.acquire(source(), job_id=uuid4())

    assert result.transcript[0].provenance == "soscripted"
    assert primary.calls == ["metadata", "transcript:native"]
    with pytest.raises(CircuitOpen):
        circuits.before_call("supadata")


def test_server_fallback_supplies_burned_in_quantities_when_apis_are_sparse() -> None:
    from ladle.acquisition.models import AcquiredVideoContext, VisualEvidence

    source_value = source()
    primary = Primary(
        native=transcript("Add flour and bake until golden.", "supadata-native"),
        generated=TranscriptUnavailable(),
        visual_result=ProviderQuotaError(),
    )
    fallback = Fallback(transcript("unused"))
    server = ContextBackup(
        AcquiredVideoContext(
            source=source_value,
            is_public=True,
            description="",
            transcript=[],
            visual_observations=[
                VisualEvidence(
                    text="2 cups flour",
                    timestamp_seconds=2,
                    provenance="server-ocr",
                    confidence=0.8,
                )
            ],
            diagnostics=[],
        )
    )
    chain = ProviderChain(
        primary=primary,
        fallback=fallback,
        server_fallback=server,
    )

    result = chain.acquire(source_value, job_id=uuid4())

    assert server.calls == 1
    assert result.visual_observations[-1].provenance == "server-ocr"
    assert "serverFallbackUsed" in result.diagnostics
