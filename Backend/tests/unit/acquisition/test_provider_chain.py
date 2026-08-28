from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest

from ladle.acquisition.errors import (
    PrivateOrDeleted,
    ProviderQuotaError,
    ProviderTransientError,
    TranscriptUnavailable,
)
from ladle.acquisition.models import (
    LinkedDocument,
    MediaMetadata,
    SourceVideoDescriptor,
    TranscriptResult,
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
    thumbnail_url: str | None = None
    description: str = "Add flour and bake."
    calls: list[str] = field(default_factory=list)

    def metadata(self, source: SourceVideoDescriptor, *, job_id: UUID) -> MediaMetadata:
        del source, job_id
        self.calls.append("metadata")
        return MediaMetadata(
            title="Recipe",
            description=self.description,
            creator_name="Creator",
            thumbnail_url=self.thumbnail_url,
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


@dataclass
class SearchEnricher:
    result: list[LinkedDocument] | Exception
    calls: int = 0

    def enrich(
        self,
        context: object,
        *,
        job_id: UUID,
    ) -> list[LinkedDocument]:
        del context, job_id
        self.calls += 1
        if isinstance(self.result, Exception):
            raise self.result
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


def test_sufficient_supadata_auto_material_skips_paid_fallbacks() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=transcript(
            "Add 2 cups flour. Mix well, then bake for 20 minutes.",
            "supadata-auto",
        ),
    )
    fallback = Fallback(transcript("unused"))
    metrics = MetricsRegistry()
    chain = ProviderChain(
        primary=primary,
        fallback=fallback,
        metrics=metrics,
    )

    context = chain.acquire(source(), job_id=uuid4())

    assert context.transcript[0].provenance == "supadata-auto"
    assert primary.calls == ["metadata", "transcript:auto"]
    assert fallback.calls == 0
    assert (
        'ladle_provider_total{outcome="success",provider="supadata"} 2'
        in metrics.render()
    )


def test_acquired_context_preserves_provider_thumbnail() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=transcript(
            "Add 2 cups flour. Mix well, then bake for 20 minutes.",
            "supadata-auto",
        ),
        thumbnail_url="https://images.example/recipe.jpg",
    )
    chain = ProviderChain(primary=primary, fallback=None)

    context = chain.acquire(source(), job_id=uuid4())

    assert context.thumbnail_url == "https://images.example/recipe.jpg"


def test_soscripted_can_run_without_supadata() -> None:
    fallback = Fallback(
        transcript(
            "Add 2 cups flour. Mix well, then bake for 20 minutes.",
            "soscripted",
        )
    )
    chain = ProviderChain(primary=None, fallback=fallback)

    context = chain.acquire(source(), job_id=uuid4())

    assert fallback.calls == 1
    assert context.transcript[0].provenance == "soscripted"


def test_public_recheck_uses_metadata_without_transcript_or_visual_spend() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=TranscriptUnavailable(),
    )
    chain = ProviderChain(
        primary=primary,
        fallback=Fallback(transcript("unused")),
    )

    assert chain.check_public(source(), job_id=uuid4())
    assert primary.calls == ["metadata"]


def test_sparse_source_uses_text_fallbacks_but_never_visual_analysis() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=ProviderQuotaError(),
    )
    fallback = Fallback(
        transcript("Add flour. Mix well, then bake for 20 minutes.", "soscripted")
    )
    chain = ProviderChain(primary=primary, fallback=fallback)

    context = chain.acquire(source(), job_id=uuid4())

    assert fallback.calls == 1
    assert context.transcript[0].provenance == "soscripted"
    assert primary.calls == ["metadata", "transcript:auto"]
    assert context.visual_observations == []
    assert "supadataTranscriptUnavailable" in context.diagnostics


def test_private_source_short_circuits_all_fallback_spend() -> None:
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=PrivateOrDeleted(),
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
        native=TranscriptUnavailable(),
        generated=ProviderQuotaError(),
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
    assert primary.calls == ["metadata", "transcript:auto"]
    with pytest.raises(CircuitOpen):
        circuits.before_call("supadata")


def test_server_fallback_merges_text_but_discards_visual_context() -> None:
    from ladle.acquisition.models import AcquiredVideoContext, VisualEvidence

    source_value = source()
    primary = Primary(
        native=transcript("Add flour and bake until golden.", "supadata-native"),
        generated=TranscriptUnavailable(),
    )
    fallback = Fallback(transcript("unused"))
    server = ContextBackup(
        AcquiredVideoContext(
            source=source_value,
            is_public=True,
            description="",
            transcript=transcript(
                "Add 2 cups flour and bake.", "server-transcript"
            ).segments,
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
    assert result.transcript[-1].provenance == "server-transcript"
    assert result.visual_observations == []
    assert "serverFallbackUsed" in result.diagnostics


def test_creator_search_runs_only_after_transcript_fallbacks_remain_sparse() -> None:
    creator_page = LinkedDocument(
        url="https://creator.example/recipe",
        text=(
            "Ingredients: 2 cups flour. Method: mix the flour with water, "
            "then bake until golden."
        ),
        provenance="creatorSearch",
    )
    search = SearchEnricher([creator_page])
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=TranscriptUnavailable(),
    )
    fallback = Fallback(transcript("This is my favorite dinner."))
    chain = ProviderChain(primary=primary, fallback=fallback, search=search)

    result = chain.acquire(source(), job_id=uuid4())

    assert primary.calls == ["metadata", "transcript:auto"]
    assert fallback.calls == 1
    assert search.calls == 1
    assert result.linked_documents == [creator_page]
    assert "creatorSearchUsed" in result.diagnostics


def test_promotional_caption_cannot_hide_sparse_recipe_evidence_from_search() -> None:
    creator_page = LinkedDocument(
        url="https://creator.example/recipe",
        text="Ingredients: 2 cups flour. Method: mix and bake until golden.",
        provenance="creatorSearch",
    )
    search = SearchEnricher([creator_page])
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=transcript("This one is so good."),
        description="Add 2 cups flour and bake tonight. Full recipe in bio.",
    )
    chain = ProviderChain(primary=primary, fallback=None, search=search)

    result = chain.acquire(source(), job_id=uuid4())

    assert search.calls == 1
    assert result.linked_documents == [creator_page]


def test_creator_search_is_skipped_when_transcript_is_recipe_bearing() -> None:
    search = SearchEnricher([])
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=transcript("Add 2 cups flour, mix well, and bake until golden."),
    )
    chain = ProviderChain(primary=primary, fallback=None, search=search)

    chain.acquire(source(), job_id=uuid4())

    assert search.calls == 0


def test_creator_search_records_when_no_creator_recipe_matches() -> None:
    search = SearchEnricher([])
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=TranscriptUnavailable(),
    )
    chain = ProviderChain(primary=primary, fallback=None, search=search)

    result = chain.acquire(source(), job_id=uuid4())

    assert search.calls == 1
    assert result.linked_documents == []
    assert "creatorSearchNoMatch" in result.diagnostics


def test_creator_search_failure_is_diagnostic_and_never_adds_visual_evidence() -> None:
    search = SearchEnricher(ProviderTransientError("search unavailable"))
    primary = Primary(
        native=TranscriptUnavailable(),
        generated=TranscriptUnavailable(),
    )
    chain = ProviderChain(primary=primary, fallback=None, search=search)

    result = chain.acquire(source(), job_id=uuid4())

    assert search.calls == 1
    assert result.visual_observations == []
    assert result.linked_documents == []
    assert "creatorSearchUnavailable" in result.diagnostics
