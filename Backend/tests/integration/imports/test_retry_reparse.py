from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from inspect import signature
from uuid import uuid4

import pytest
from pydantic import SecretStr
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.acquisition.errors import ProviderTransientError
from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
)
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.contracts.recipes import (
    FieldUncertaintyDTO,
    RecipeReviewStatus,
    RecipeSource,
)
from ladle.crypto.private_text import LocalPrivateTextCipher
from ladle.db.models import (
    ExtractionCache,
    FieldUncertainty,
    ImportJob,
    NegativeExtractionCache,
    Nutrition,
    Recipe,
    RecipeImage,
    SourceVideo,
)
from ladle.db.session import build_engine
from ladle.extraction.verification import VerificationEvidence
from ladle.imports.admission import AdmissionService
from ladle.imports.orchestrator import ImportOrchestrator, ProcessOutcome
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.imports.thumbnails import ThumbnailAsset
from ladle.imports.transitions import ImportRetryService, ImportTransitionService
from ladle.recipes.template_clone import (
    RecipeTemplate,
    RecipeTemplateCloner,
    TemplateNutrition,
)
from ladle.usage.limits import UsageLimitExceeded
from tests.e2e.test_fake_import_round_trip import seed_import
from tests.fakes.acquisition import FakeAcquirer
from tests.fakes.extraction import FakeExtractor
from tests.integration.recipes.test_recipe_service import manual_recipe
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeThumbnailFetcher:
    asset: ThumbnailAsset | None
    downloads: int = 0
    stores: int = 0

    def download(
        self,
        source: object,
        *,
        candidate_url: str | None = None,
    ) -> ThumbnailAsset | None:
        del source, candidate_url
        self.downloads += 1
        return self.asset

    def store(self, source: object, asset: ThumbnailAsset) -> str:
        del source, asset
        self.stores += 1
        return "thumbnails/retry/thumb.jpg"


@dataclass
class FakeNutritionEnricher:
    result: TemplateNutrition | None = None
    failure: Exception | None = None
    calls: list[RecipeTemplate] = field(default_factory=list)

    def enrich(
        self,
        template: RecipeTemplate,
        **_kwargs: object,
    ) -> RecipeTemplate:
        self.calls.append(template)
        if self.failure is not None:
            return template.model_copy(
                update={
                    "review_status": RecipeReviewStatus.NEEDS_REVIEW,
                    "uncertainties": [
                        *template.uncertainties,
                        FieldUncertaintyDTO(
                            field="nutrition",
                            reason="USDA nutrition data was unavailable.",
                        ),
                    ],
                }
            )
        if self.result is None:
            return template
        return template.model_copy(update={"nutrition": self.result})


@dataclass
class FakeRecipeVerifier:
    calls: list[tuple[RecipeTemplate, list[VerificationEvidence]]] = field(
        default_factory=list
    )

    def verify(
        self,
        template: RecipeTemplate,
        *,
        evidence: list[VerificationEvidence],
        job_id: object,
    ) -> RecipeTemplate:
        del job_id
        self.calls.append((template, evidence))
        return template.model_copy(update={"title": "Verified Lemon Orzo"})


def services(
    database_url: str,
    clock: FrozenClock,
    *,
    template: RecipeTemplate,
    thumbnails: FakeThumbnailFetcher | None = None,
    nutrition_enricher: FakeNutritionEnricher | None = None,
    verifier: FakeRecipeVerifier | None = None,
) -> tuple[
    sessionmaker[Session],
    ImportOrchestrator,
    ImportRetryService,
    FakeAcquirer,
    FakeExtractor,
]:
    engine = build_engine(database_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    reservations = ReservationService(clock=clock, lifetime=timedelta(hours=1))
    cloner = RecipeTemplateCloner(clock=clock, reservations=reservations)
    claims = ExtractionClaimService(clock=clock, lease_duration=timedelta(minutes=5))
    cache = ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=cloner,
        public_recheck_after=timedelta(days=7),
    )
    acquirer = FakeAcquirer()
    extractor = FakeExtractor(template)
    cipher = LocalPrivateTextCipher(SecretStr("retry-test-encryption-key"))
    return (
        sessions,
        ImportOrchestrator(
            session_factory=sessions,
            cache=cache,
            acquirer=acquirer,
            extractor=extractor,
            clock=clock,
            thumbnails=thumbnails,  # type: ignore[arg-type]
            nutrition_enricher=nutrition_enricher,
            verifier=verifier,
            private_text=cipher,
            private_completion=cloner,
            transitions=ImportTransitionService(
                clock=clock,
                reservations=reservations,
            ),
        ),
        ImportRetryService(
            clock=clock,
            reservations=reservations,
            private_text=cipher,
        ),
        acquirer,
        extractor,
    )


@pytest.mark.integration
def test_import_persists_deterministically_calculated_nutrition(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 8, 24, 12, 0, tzinfo=UTC))
    nutrition = TemplateNutrition(
        calories="420.0",
        protein_grams="18.0",
        carbohydrate_grams="52.0",
        fat_grams="16.0",
        serving_basis="4",
        is_estimated=True,
        basis="usdaCalculated",
        evidence="USDA FDC 123",
    )
    calculator = FakeNutritionEnricher(result=nutrition)
    template = RecipeTemplate.from_recipe(manual_recipe(uuid4())).model_copy(
        update={"nutrition": None, "servings_basis": "stated"}
    )
    sessions, orchestrator, _, _, _ = services(
        clean_postgres_url,
        clock,
        template=template,
        nutrition_enricher=calculator,
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="nutrition-calculated",
                canonical_url="https://www.youtube.com/watch?v=nutrition-calculated",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="nutrition")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    assert len(calculator.calls) == 1
    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        stored = database.get(Nutrition, job.current_recipe_id)
        assert stored is not None
        assert stored.calories == 420
        assert stored.protein_grams == 18
        assert stored.is_estimated


@pytest.mark.integration
def test_creator_facts_are_applied_before_nutrition_calculation(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 8, 24, 12, 0, tzinfo=UTC))
    copied = TemplateNutrition(
        calories="160",
        protein_grams="1",
        carbohydrate_grams="35",
        fat_grams="2",
        serving_basis="6",
        is_estimated=False,
        basis="creatorStated",
        evidence="model copy with incorrect serving basis",
    )
    calculator = FakeNutritionEnricher()
    template = RecipeTemplate.from_recipe(manual_recipe(uuid4())).model_copy(
        update={
            "servings": Decimal(1),
            "servings_basis": "unknown",
            "nutrition": copied,
            "review_status": RecipeReviewStatus.NEEDS_REVIEW,
        }
    )
    sessions, orchestrator, _, acquirer, _ = services(
        clean_postgres_url,
        clock,
        template=template,
        nutrition_enricher=calculator,
    )
    acquirer.transcript_text = (
        "Add 2 cups orzo and simmer for 10 minutes. Makes 6 servings. "
        "Nutrients per serving: Calories 160, Protein 1 g, "
        "Carbohydrates 35 g, Total Fat 2 g."
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="creator-facts",
                canonical_url="https://www.youtube.com/watch?v=creator-facts",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="creator-facts")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    observed = calculator.calls[0]
    assert observed.servings == 6
    assert observed.servings_basis == "stated"
    assert observed.nutrition is not None
    assert observed.nutrition.serving_basis == 1


@pytest.mark.integration
def test_usda_failure_completes_import_with_nutrition_review_uncertainty(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 8, 24, 12, 0, tzinfo=UTC))
    calculator = FakeNutritionEnricher(
        failure=ProviderTransientError("USDA unavailable")
    )
    template = RecipeTemplate.from_recipe(manual_recipe(uuid4())).model_copy(
        update={"nutrition": None, "servings_basis": "stated"}
    )
    sessions, orchestrator, _, _, _ = services(
        clean_postgres_url,
        clock,
        template=template,
        nutrition_enricher=calculator,
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="nutrition-unavailable",
                canonical_url="https://www.youtube.com/watch?v=nutrition-unavailable",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="nutrition-down")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        assert job.status == "needsReview"
        assert database.get(Nutrition, job.current_recipe_id) is None
        uncertainty = database.scalar(
            select(FieldUncertainty).where(
                FieldUncertainty.recipe_id == job.current_recipe_id,
                FieldUncertainty.field == "nutrition",
            )
        )
        assert uncertainty is not None
        assert "unavailable" in uncertainty.reason.casefold()


@pytest.mark.integration
def test_verification_runs_after_nutrition_with_text_evidence_before_persistence(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 8, 24, 12, 0, tzinfo=UTC))
    nutrition = TemplateNutrition(
        calories="420",
        protein_grams="18",
        carbohydrate_grams="52",
        fat_grams="16",
        serving_basis="4",
        is_estimated=True,
        basis="usdaCalculated",
        evidence="USDA FDC 123",
    )
    calculator = FakeNutritionEnricher(result=nutrition)
    verifier = FakeRecipeVerifier()
    template = RecipeTemplate.from_recipe(manual_recipe(uuid4())).model_copy(
        update={"nutrition": None, "servings_basis": "stated"}
    )
    sessions, orchestrator, _, _, _ = services(
        clean_postgres_url,
        clock,
        template=template,
        nutrition_enricher=calculator,
        verifier=verifier,
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="verified-recipe",
                canonical_url="https://www.youtube.com/watch?v=verified-recipe",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="verified")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    assert verifier.calls[0][0].nutrition == nutrition
    assert any(
        "two cups orzo" in value.text.casefold()
        for value in verifier.calls[0][1]
    )
    with sessions() as database:
        job = database.get(ImportJob, job_id)
        recipe_row = database.get(Recipe, job.current_recipe_id if job else None)
        assert recipe_row is not None
        assert recipe_row.title == "Verified Lemon Orzo"


def test_import_runtime_has_no_thumbnail_analysis_hook() -> None:
    assert "thumbnail_observer" not in signature(ImportOrchestrator).parameters


@pytest.mark.integration
def test_sparse_source_fails_before_extraction_without_persisting_recipe(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 8, 24, 12, 0, tzinfo=UTC))
    sessions, orchestrator, _, acquirer, extractor = services(
        clean_postgres_url,
        clock,
        template=RecipeTemplate.from_recipe(manual_recipe(uuid4())),
    )
    acquirer.transcript_text = None
    acquirer.title = "The creamiest pasta"
    acquirer.description = "You need this tonight. Full recipe in bio."
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="instagram",
                platform_video_id="sparse-evidence",
                canonical_url="https://www.instagram.com/reel/sparse-evidence",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="sparse")

    assert orchestrator.process(job_id) == ProcessOutcome.FAILED
    assert extractor.calls == []
    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        assert job.status == "failed"
        assert job.failure_reason == "insufficientTextEvidence"
        assert job.diagnostic_code == "insufficientTextEvidence"
        assert job.current_recipe_id is None
        assert job.candidate_recipe_id is None
        assert database.scalar(select(func.count()).select_from(Recipe)) == 0


@pytest.mark.integration
def test_correction_reparse_replaces_unchanged_recipe_without_poisoning_cache(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=retry-test",
        }
    )
    template = RecipeTemplate.from_recipe(recipe)
    thumbnails = FakeThumbnailFetcher(
        ThumbnailAsset(
            data=b"thumbnail-bytes",
            content_type="image/jpeg",
            extension=".jpg",
        )
    )
    sessions, orchestrator, retry, acquirer, extractor = services(
        clean_postgres_url,
        clock,
        template=template,
        thumbnails=thumbnails,
    )
    acquirer.thumbnail_url = "https://images.example/retry.jpg"
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="retry-test",
                canonical_url="https://www.youtube.com/watch?v=retry-test",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="retry")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    assert extractor.calls[-1].visual_observations == []
    assert thumbnails.downloads == 1
    assert thumbnails.stores == 1
    with sessions() as database:
        original_job = database.get(ImportJob, job_id)
        assert original_job is not None
        original_recipe_id = original_job.current_recipe_id
        assert original_recipe_id is not None
        assert database.scalar(select(func.count()).select_from(ExtractionCache)) == 1

    with sessions.begin() as database:
        retried = retry.retry(
            database,
            user_id=original_job.user_id,
            job_id=job_id,
            correction_notes="Use the quantity shown at 00:04.",
            pasted_text=None,
        )
        assert retried.bypass_cache
        assert retried.correction_notes_encrypted is not None
        assert b"quantity shown" not in retried.correction_notes_encrypted

    extractor.template = template.model_copy(update={"title": "Corrected Lemon Orzo"})
    assert orchestrator.process(job_id) == ProcessOutcome.PRIVATE_COMPLETED
    assert extractor.calls[-1].visual_observations == []
    assert thumbnails.downloads == 2
    assert thumbnails.stores == 2

    with sessions() as database:
        completed = database.get(ImportJob, job_id)
        stored = database.get(Recipe, original_recipe_id)
        assert completed is not None
        assert completed.current_recipe_id == original_recipe_id
        assert completed.cache_entry_id is None
        assert stored is not None
        assert stored.title == "Corrected Lemon Orzo"
        assert stored.revision == 2
        image = database.scalar(
            select(RecipeImage).where(RecipeImage.recipe_id == original_recipe_id)
        )
        assert image is not None
        assert image.object_key == "thumbnails/retry/thumb.jpg"
        assert completed.correction_notes_encrypted is None
        assert completed.pasted_text_encrypted is None
        assert database.scalar(select(func.count()).select_from(ExtractionCache)) == 1


@pytest.mark.integration
def test_empty_acquisition_fails_instead_of_saving_placeholder_recipe(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    sessions, orchestrator, _, acquirer, extractor = services(
        clean_postgres_url,
        clock,
        template=RecipeTemplate.from_recipe(manual_recipe(uuid4())),
    )
    source_id = uuid4()
    with sessions.begin() as database:
        database.add(
            SourceVideo(
                id=source_id,
                platform="tiktok",
                platform_video_id="empty-source",
                canonical_url=("https://www.tiktok.com/@creator/video/empty-source"),
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="empty-source")
    acquirer.context = AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=source_id,
            platform="tiktok",
            platform_video_id="empty-source",
            canonical_url="https://www.tiktok.com/@creator/video/empty-source",
            source_revision="1",
        ),
        is_public=True,
        description="",
        diagnostics=["metadataUnavailable"],
    )

    assert orchestrator.process(job_id) == ProcessOutcome.FAILED
    assert extractor.calls == []
    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        assert job.status == "failed"
        assert job.failure_reason == "insufficientTextEvidence"
        assert job.diagnostic_code == "insufficientTextEvidence"
@pytest.mark.integration
def test_pasted_text_skips_acquisition_and_stale_edit_preserves_current_recipe(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=paste-test",
        }
    )
    template = RecipeTemplate.from_recipe(recipe)
    thumbnails = FakeThumbnailFetcher(
        ThumbnailAsset(
            data=b"thumbnail-bytes",
            content_type="image/jpeg",
            extension=".jpg",
        )
    )
    sessions, orchestrator, retry, acquirer, extractor = services(
        clean_postgres_url,
        clock,
        template=template,
        thumbnails=thumbnails,
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="paste-test",
                canonical_url="https://www.youtube.com/watch?v=paste-test",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="paste")
    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    initial_acquisition_calls = len(acquirer.calls)

    with sessions.begin() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        retry.retry(
            database,
            user_id=job.user_id,
            job_id=job_id,
            correction_notes=None,
            pasted_text="1 slice bread. Toast the bread.",
        )
        current = database.get(Recipe, job.current_recipe_id)
        assert current is not None
        current.title = "User Edited Title"
        current.revision += 1

    extractor.template = template.model_copy(
        update={
            "title": "Automated Replacement",
            "review_status": RecipeReviewStatus.READY,
        }
    )
    assert orchestrator.process(job_id) == ProcessOutcome.PRIVATE_NEEDS_REVIEW
    assert len(acquirer.calls) == initial_acquisition_calls

    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        current = database.get(Recipe, job.current_recipe_id)
        candidate = database.get(Recipe, job.candidate_recipe_id)
        assert current is not None
        assert current.title == "User Edited Title"
        assert candidate is not None
        assert candidate.title == "Automated Replacement"
        image = database.scalar(
            select(RecipeImage).where(RecipeImage.recipe_id == candidate.id)
        )
        assert image is not None
        assert image.object_key == "thumbnails/retry/thumb.jpg"
        assert job.status == "needsReview"
        assert job.correction_notes_encrypted is None
        assert job.pasted_text_encrypted is None
        admission = AdmissionService(
            parser=SourceIdentityParser(),
            reservations=ReservationService(
                clock=clock,
                lifetime=timedelta(hours=1),
            ),
            clock=clock,
        )
        assert admission.response(job).recipe_id == candidate.id


@pytest.mark.integration
def test_failed_private_reparse_preserves_current_recipe_and_invalidates_cache(
    clean_postgres_url: str,
) -> None:
    from ladle.acquisition.errors import PrivateOrDeleted

    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=private-reparse",
        }
    )
    sessions, orchestrator, retry, acquirer, _ = services(
        clean_postgres_url,
        clock,
        template=RecipeTemplate.from_recipe(recipe),
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="private-reparse",
                canonical_url=("https://www.youtube.com/watch?v=private-reparse"),
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="private")

    assert orchestrator.process(job_id) == ProcessOutcome.COMPLETED
    with sessions.begin() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        current_recipe_id = job.current_recipe_id
        assert current_recipe_id is not None
        retry.retry(
            database,
            user_id=job.user_id,
            job_id=job_id,
            correction_notes="The creator removed the video.",
            pasted_text=None,
        )

    acquirer.failure = PrivateOrDeleted()
    assert orchestrator.process(job_id) == ProcessOutcome.FAILED

    with sessions() as database:
        job = database.get(ImportJob, job_id)
        current = database.get(Recipe, current_recipe_id)
        assert job is not None
        assert current is not None
        assert current.title == recipe.title
        assert job.current_recipe_id == current_recipe_id
        assert job.candidate_recipe_id is None
        assert job.status == "failed"
        assert job.failure_reason == "privateOrDeleted"
        assert job.correction_notes_encrypted is None
        assert (
            database.scalar(select(func.count()).select_from(NegativeExtractionCache))
            == 1
        )
        assert (
            database.scalar(
                select(func.count())
                .select_from(ExtractionCache)
                .where(ExtractionCache.invalidated_at.is_(None))
            )
            == 0
        )


@pytest.mark.integration
def test_provider_budget_exhaustion_is_a_typed_terminal_import_failure(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    recipe = manual_recipe(uuid4())
    sessions, orchestrator, _, acquirer, _ = services(
        clean_postgres_url,
        clock,
        template=RecipeTemplate.from_recipe(recipe),
    )
    with sessions.begin() as database:
        source_id = uuid4()
        database.add(
            SourceVideo(
                id=source_id,
                platform="youtube",
                platform_video_id="budget-exhausted",
                canonical_url="https://www.youtube.com/watch?v=budget-exhausted",
                source_revision="1",
                source_metadata={},
            )
        )
        job_id = seed_import(database, source_id=source_id, suffix="budget")

    acquirer.failure = UsageLimitExceeded("budget exhausted")
    assert orchestrator.process(job_id) == ProcessOutcome.FAILED

    with sessions() as database:
        job = database.get(ImportJob, job_id)
        assert job is not None
        assert job.status == "failed"
        assert job.failure_reason == "quotaExceeded"
        assert job.diagnostic_code == "UsageLimitExceeded"
