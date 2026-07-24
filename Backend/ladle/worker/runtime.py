from datetime import timedelta
from decimal import Decimal
from functools import lru_cache

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.clock import SystemClock
from ladle.config import Settings
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.db.session import build_engine, build_session_factory
from ladle.imports.orchestrator import ImportOrchestrator
from ladle.imports.reservations import ReservationService
from ladle.recipes.template_clone import (
    RecipeTemplate,
    RecipeTemplateCloner,
    TemplateIngredient,
    TemplateStep,
    TemplateTimer,
)


class FakeRuntimeAcquirer:
    def acquire(self, source: SourceVideoDescriptor) -> AcquiredVideoContext:
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

    def extract(self, context: AcquiredVideoContext) -> RecipeTemplate:
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
    if settings.worker_provider_mode != "fake":
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
    return ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=FakeRuntimeAcquirer(),
        extractor=FakeRuntimeExtractor(),
        clock=clock,
    )
