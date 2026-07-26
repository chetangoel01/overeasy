import logging
from datetime import timedelta
from decimal import Decimal
from functools import lru_cache
from uuid import UUID

import httpx
from anthropic import Anthropic
from sqlalchemy.orm import Session, sessionmaker

from ladle.acquisition.audio import (
    AudioTranscriptProvider,
    MediaAudioSource,
    WhisperTranscriber,
)
from ladle.acquisition.free import (
    FreeAcquirer,
    InstagramEmbedClient,
    SafeLinkFetcher,
    TikTokPageClient,
    YtDlpClient,
)
from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.acquisition.protocol import VideoAcquirer
from ladle.acquisition.provider_chain import ProviderChain
from ladle.acquisition.soscripted import SoScriptedClient
from ladle.acquisition.supadata import SupadataClient
from ladle.acquisition.vision import (
    FrameSampler,
    VisionObserver,
    VisionVisualProvider,
)
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.crypto.private_text import LocalPrivateTextCipher
from ladle.db.session import build_engine, build_session_factory
from ladle.extraction.claude import (
    AnthropicStructuredClient,
    ClaudeRecipeExtractor,
)
from ladle.extraction.openrouter import OpenRouterStructuredClient
from ladle.extraction.protocol import RecipeExtractor
from ladle.imports.heartbeat import ClaimHeartbeatMonitor
from ladle.imports.maintenance import ImportMaintenanceService
from ladle.imports.orchestrator import ImportOrchestrator
from ladle.imports.outbox import DispatchOutboxService
from ladle.imports.reservations import ReservationService
from ladle.imports.thumbnails import OEmbedThumbnailFetcher
from ladle.imports.transitions import ImportTransitionService
from ladle.infrastructure.object_storage import S3ObjectStorage
from ladle.observability.metrics import MetricsRegistry
from ladle.recipes.template_clone import (
    RecipeTemplate,
    RecipeTemplateCloner,
    TemplateIngredient,
    TemplateStep,
    TemplateTimer,
)
from ladle.usage.circuit import CircuitBreaker
from ladle.usage.ledger import ProviderUsageLedger
from ladle.usage.limits import UsageLimitService

LOGGER = logging.getLogger(__name__)


class FakeRuntimeAcquirer:
    def check_public(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> bool:
        del source, job_id
        return True

    def acquire(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> AcquiredVideoContext:
        del job_id
        return AcquiredVideoContext(
            source=source,
            is_public=True,
            title="One-Pot Lemon Orzo",
            description="A deterministic local-stack import.",
            creator_name="Ladle Test Kitchen",
            language="en",
            transcript=[
                TextEvidence(
                    text=(
                        "Cook two cups of orzo with four cups of stock, "
                        "then stir for ten minutes."
                    ),
                    start_seconds=0,
                    end_seconds=8,
                    provenance="fake-native-caption",
                    generated=False,
                )
            ],
            visual_observations=[],
            diagnostics=[],
        )


class FakeRuntimeExtractor:
    contract_version = "v1"
    prompt_version = "fake-recipe-v1"
    model_id = "fake-extractor"

    def extract(
        self,
        context: AcquiredVideoContext,
        *,
        job_id: UUID,
    ) -> RecipeTemplate:
        del job_id
        return RecipeTemplate(
            title=context.title or "Imported Recipe",
            description=context.description,
            creator_name=context.creator_name,
            source=RecipeSource(context.source.platform),
            original_url=context.source.canonical_url,
            total_minutes=10,
            servings=Decimal("4"),
            ingredients=[
                TemplateIngredient(
                    quantity_text="2 cups",
                    normalized_quantity=Decimal("2"),
                    unit="cup",
                    name="orzo",
                    order_index=0,
                )
            ],
            steps=[
                TemplateStep(
                    order_index=0,
                    instruction="Cook the orzo, stirring until tender.",
                    ingredient_indexes=[0],
                    timers=[
                        TemplateTimer(
                            label="Cook orzo",
                            duration_seconds=600,
                        )
                    ],
                )
            ],
            review_status=RecipeReviewStatus.READY,
        )


def _audio_transcriber(
    settings: Settings,
    *,
    usage: ProviderUsageLedger,
) -> AudioTranscriptProvider | None:
    if not settings.audio_transcription_enabled or settings.openrouter_api_key is None:
        return None
    source = MediaAudioSource(
        http=httpx.Client(
            timeout=settings.transcription_timeout_seconds,
            trust_env=False,
        ),
    )
    if not source.available:
        LOGGER.warning("ffmpeg is missing; audio transcription is disabled")
        return None
    return AudioTranscriptProvider(
        audio_source=source,
        transcriber=WhisperTranscriber(
            http=httpx.Client(
                timeout=settings.transcription_timeout_seconds,
                trust_env=False,
            ),
            api_key=settings.openrouter_api_key.get_secret_value(),
            base_url=str(settings.openrouter_base_url),
            model_id=settings.transcription_model_id,
            max_audio_bytes=settings.transcription_max_audio_bytes,
            usage=usage,
        ),
        max_duration_seconds=settings.transcription_max_duration_seconds,
    )


def _vision_provider(
    settings: Settings,
    *,
    usage: ProviderUsageLedger,
) -> VisionVisualProvider | None:
    if not settings.frame_analysis_enabled or settings.openrouter_api_key is None:
        return None
    media = MediaAudioSource(
        http=httpx.Client(
            timeout=settings.frame_analysis_timeout_seconds,
            trust_env=False,
        ),
    )
    sampler = FrameSampler(max_frames=settings.frame_analysis_max_frames)
    if not sampler.available:
        LOGGER.warning("ffmpeg is missing; frame analysis is disabled")
        return None
    return VisionVisualProvider(
        media_source=media,
        sampler=sampler,
        observer=VisionObserver(
            http=httpx.Client(
                timeout=settings.frame_analysis_timeout_seconds,
                trust_env=False,
            ),
            api_key=settings.openrouter_api_key.get_secret_value(),
            base_url=str(settings.openrouter_base_url),
            model_id=settings.frame_analysis_model_id,
            usage=usage,
        ),
    )


def _free_acquirer(settings: Settings) -> FreeAcquirer | None:
    if not settings.free_acquisition_enabled:
        return None
    ytdlp = _ytdlp(settings)
    # TikTok's own ASR track needs a fetcher even when caption-link following
    # is off, so the page client gets its own.
    page_fetcher = SafeLinkFetcher(
        http=httpx.Client(
            timeout=settings.linked_page_timeout_seconds,
            trust_env=False,
        )
    )
    return FreeAcquirer(
        ytdlp=ytdlp,
        fetcher=page_fetcher if settings.free_acquisition_follow_links else None,
        tiktok=TikTokPageClient(fetcher=page_fetcher),
        instagram=InstagramEmbedClient(fetcher=page_fetcher),
        follow_caption_links=settings.free_acquisition_follow_links,
        subtitles_enabled=settings.free_acquisition_subtitles,
    )


def _ytdlp(settings: Settings) -> YtDlpClient:
    return YtDlpClient(
        binary=settings.ytdlp_binary_path,
        cookies_file=settings.ytdlp_cookies_file,
        metadata_timeout_seconds=settings.ytdlp_timeout_seconds,
        subtitle_timeout_seconds=settings.ytdlp_timeout_seconds,
        http=httpx.Client(
            timeout=settings.ytdlp_timeout_seconds,
            trust_env=False,
        ),
    )


@lru_cache(maxsize=1)
def runtime_sessions() -> sessionmaker[Session]:
    return build_session_factory(build_engine(Settings().database_url))


@lru_cache(maxsize=1)
def runtime_maintenance() -> ImportMaintenanceService:
    """Reclaim abandoned imports.

    Deliberately free of provider configuration: a stack whose providers are
    disabled or misconfigured is exactly the one most likely to strand jobs,
    so the sweep has to run when `runtime_orchestrator` cannot be built.
    """

    settings = Settings()
    return ImportMaintenanceService(
        clock=SystemClock(),
        stale_after=timedelta(minutes=settings.import_stale_after_minutes),
    )


@lru_cache(maxsize=1)
def runtime_dispatch_outbox() -> DispatchOutboxService:
    settings = Settings()
    return DispatchOutboxService(
        session_factory=runtime_sessions(),
        clock=SystemClock(),
        stale_after=timedelta(minutes=settings.import_stale_after_minutes),
        maximum_dispatches=settings.import_dispatch_maximum_attempts,
    )


@lru_cache(maxsize=1)
def runtime_orchestrator() -> ImportOrchestrator:
    settings = Settings()
    if settings.worker_provider_mode == "disabled":
        raise RuntimeError(
            "worker providers are disabled; configure live providers or "
            "set LADLE_WORKER_PROVIDER_MODE=fake for the local stack"
        )
    clock = SystemClock()
    sessions = runtime_sessions()
    reservations = ReservationService(
        clock=clock,
        lifetime=timedelta(minutes=settings.import_reservation_minutes),
    )
    claims = ExtractionClaimService(
        clock=clock,
        lease_duration=timedelta(minutes=settings.extraction_claim_minutes),
    )
    cloner = RecipeTemplateCloner(clock=clock, reservations=reservations)
    metrics = MetricsRegistry()
    cache = ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=cloner,
        public_recheck_after=timedelta(days=settings.public_cache_recheck_days),
        metrics=metrics,
    )
    acquirer: VideoAcquirer
    extractor: RecipeExtractor
    if settings.worker_provider_mode == "fake":
        acquirer = FakeRuntimeAcquirer()
        extractor = FakeRuntimeExtractor()
    else:
        extraction_key = (
            settings.openrouter_api_key
            if settings.extraction_provider == "openrouter"
            else settings.anthropic_api_key
        )
        if extraction_key is None:
            raise RuntimeError(
                f"live workers require an {settings.extraction_provider} API key"
            )
        usage_limits = UsageLimitService(
            clock=clock,
            window=timedelta(days=1),
            max_billed_units=settings.provider_daily_billed_unit_limit,
            reservation_lifetime=timedelta(
                minutes=settings.provider_budget_reservation_minutes
            ),
        )
        usage = ProviderUsageLedger(
            session_factory=sessions,
            clock=clock,
            limits=usage_limits,
            reservation_units=settings.provider_reservation_billed_units,
        )
        acquirer = ProviderChain(
            primary=(
                SupadataClient(
                    http=httpx.Client(
                        timeout=settings.supadata_timeout_seconds,
                        trust_env=False,
                    ),
                    api_key=settings.supadata_api_key,
                    base_url=str(settings.supadata_base_url),
                    usage=usage,
                )
                if settings.supadata_api_key is not None
                else None
            ),
            fallback=(
                SoScriptedClient(
                    http=httpx.Client(
                        timeout=settings.soscripted_timeout_seconds,
                        trust_env=False,
                    ),
                    api_key=settings.soscripted_api_key,
                    base_url=str(settings.soscripted_base_url),
                    usage=usage,
                )
                if settings.soscripted_api_key is not None
                else None
            ),
            circuits=CircuitBreaker(
                clock=clock,
                failure_threshold=settings.provider_circuit_failure_threshold,
                cooldown=timedelta(seconds=settings.provider_circuit_cooldown_seconds),
            ),
            free=_free_acquirer(settings),
            audio=_audio_transcriber(settings, usage=usage),
            vision=_vision_provider(settings, usage=usage),
            metrics=metrics,
        )
        if settings.extraction_provider == "openrouter":
            assert settings.openrouter_api_key is not None
            extractor = ClaudeRecipeExtractor(
                client=OpenRouterStructuredClient(
                    http=httpx.Client(
                        timeout=settings.openrouter_timeout_seconds,
                        trust_env=False,
                    ),
                    api_key=settings.openrouter_api_key.get_secret_value(),
                    base_url=str(settings.openrouter_base_url),
                ),
                model_id=settings.openrouter_model_id,
                max_tokens=settings.openrouter_max_tokens,
                usage=usage,
                provider="openrouter",
            )
        else:
            assert settings.anthropic_api_key is not None
            extractor = ClaudeRecipeExtractor(
                client=AnthropicStructuredClient(
                    Anthropic(
                        api_key=settings.anthropic_api_key.get_secret_value(),
                        base_url=str(settings.anthropic_base_url),
                        timeout=settings.anthropic_timeout_seconds,
                    )
                ),
                model_id=settings.anthropic_model_id,
                max_tokens=settings.anthropic_max_tokens,
                usage=usage,
            )
    thumbnails: OEmbedThumbnailFetcher | None = None
    if settings.object_storage_enabled:
        thumbnails = OEmbedThumbnailFetcher(
            http=httpx.Client(timeout=15.0, trust_env=False),
            storage=S3ObjectStorage(
                endpoint_url=str(settings.object_storage_endpoint_url),
                region=settings.object_storage_region,
                bucket=settings.object_storage_bucket,
                access_key=settings.object_storage_access_key,
                secret_key=settings.object_storage_secret_key.get_secret_value(),
            ),
        )
    return ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=acquirer,
        extractor=extractor,
        clock=clock,
        thumbnails=thumbnails,
        private_text=LocalPrivateTextCipher(settings.data_encryption_key),
        private_completion=cloner,
        transitions=ImportTransitionService(
            clock=clock,
            reservations=reservations,
        ),
        metrics=metrics,
        heartbeat=ClaimHeartbeatMonitor(
            session_factory=sessions,
            claims=claims,
            interval_seconds=settings.extraction_claim_heartbeat_seconds,
        ),
    )
