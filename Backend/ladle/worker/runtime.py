from datetime import timedelta
from decimal import Decimal
from functools import lru_cache
from uuid import UUID

import httpx
from anthropic import Anthropic

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.acquisition.protocol import VideoAcquirer
from ladle.acquisition.provider_chain import ProviderChain
from ladle.acquisition.soscripted import SoScriptedClient
from ladle.acquisition.supadata import SupadataClient
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.db.session import build_engine, build_session_factory
from ladle.extraction.claude import (
    AnthropicStructuredClient,
    ClaudeRecipeExtractor,
)
from ladle.extraction.protocol import RecipeExtractor
from ladle.imports.orchestrator import ImportOrchestrator
from ladle.imports.reservations import ReservationService
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


class FakeRuntimeAcquirer:
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


@lru_cache(maxsize=1)
def runtime_orchestrator() -> ImportOrchestrator:
    settings = Settings()
    if settings.worker_provider_mode == "disabled":
        raise RuntimeError(
            "worker providers are disabled; configure live providers or "
            "set LADLE_WORKER_PROVIDER_MODE=fake for the local stack"
        )
    clock = SystemClock()
    sessions = build_session_factory(build_engine(settings.database_url))
    reservations = ReservationService(
        clock=clock,
        lifetime=timedelta(minutes=settings.import_reservation_minutes),
    )
    claims = ExtractionClaimService(
        clock=clock,
        lease_duration=timedelta(minutes=settings.extraction_claim_minutes),
    )
    cache = ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=RecipeTemplateCloner(clock=clock, reservations=reservations),
        public_recheck_after=timedelta(days=settings.public_cache_recheck_days),
    )
    acquirer: VideoAcquirer
    extractor: RecipeExtractor
    if settings.worker_provider_mode == "fake":
        acquirer = FakeRuntimeAcquirer()
        extractor = FakeRuntimeExtractor()
    else:
        if (
            settings.supadata_api_key is None
            or settings.soscripted_api_key is None
            or settings.anthropic_api_key is None
        ):
            raise RuntimeError(
                "live workers require Supadata, SoScripted, and Anthropic API keys"
            )
        usage = ProviderUsageLedger(session_factory=sessions, clock=clock)
        acquirer = ProviderChain(
            primary=SupadataClient(
                http=httpx.Client(timeout=settings.supadata_timeout_seconds),
                api_key=settings.supadata_api_key,
                base_url=str(settings.supadata_base_url),
                usage=usage,
            ),
            fallback=SoScriptedClient(
                http=httpx.Client(timeout=settings.soscripted_timeout_seconds),
                api_key=settings.soscripted_api_key,
                base_url=str(settings.soscripted_base_url),
                usage=usage,
            ),
            circuits=CircuitBreaker(
                clock=clock,
                failure_threshold=settings.provider_circuit_failure_threshold,
                cooldown=timedelta(seconds=settings.provider_circuit_cooldown_seconds),
            ),
        )
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
    return ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=acquirer,
        extractor=extractor,
        clock=clock,
        usage_limits=UsageLimitService(
            clock=clock,
            window=timedelta(days=1),
            max_billed_units=settings.provider_daily_billed_unit_limit,
        ),
    )
