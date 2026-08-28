import time
from dataclasses import dataclass, field
from decimal import Decimal
from uuid import UUID, uuid4

import httpx
import pytest

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.extraction.verification import (
    OpenRouterVerificationClient,
    StructuredVerificationResponse,
    TargetedRecipeVerifier,
    VerificationEvidence,
    VerificationIssue,
    VerificationPatch,
    VerificationResponse,
    VerificationUnavailable,
    _decimal,
    deterministic_issues,
    verification_evidence,
)
from ladle.recipes.template_clone import (
    RecipeTemplate,
    TemplateIngredient,
    TemplateNutrition,
    TemplateStep,
)


@dataclass
class Model:
    patches: list[VerificationPatch] = field(default_factory=list)
    calls: list[dict[str, object]] = field(default_factory=list)
    cost_usd: Decimal | None = None

    def propose_patches(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        issues: list[VerificationIssue],
        evidence: list[VerificationEvidence],
    ) -> StructuredVerificationResponse:
        self.calls.append(
            {
                "model": model,
                "max_tokens": max_tokens,
                "template": template,
                "issues": issues,
                "evidence": evidence,
            }
        )
        return StructuredVerificationResponse(
            parsed_output=VerificationResponse(patches=self.patches),
            input_tokens=50,
            output_tokens=20,
            cost_usd=self.cost_usd,
        )


@dataclass
class Usage:
    starts: list[dict[str, object]] = field(default_factory=list)
    completions: int = 0
    completion_values: dict[str, object] = field(default_factory=dict)
    failures: int = 0

    def existing_external_job_id(
        self,
        *,
        job_id: UUID,
        idempotency_key: str,
    ) -> str | None:
        del job_id, idempotency_key
        return None

    def started(self, **values: object) -> None:
        self.starts.append(values)

    def completed(self, **values: object) -> None:
        self.completion_values = values
        self.completions += 1

    def failed(self, **values: object) -> None:
        del values
        self.failures += 1


def evidence(text: str, provenance: str = "creator-page") -> VerificationEvidence:
    return VerificationEvidence(text=text, provenance=provenance)


def ingredient(name: str, index: int) -> TemplateIngredient:
    return TemplateIngredient(
        name=name,
        quantity_text="1 slice",
        normalized_quantity=Decimal("1"),
        unit="slice",
        usda_search_term=name,
        order_index=index,
    )


def recipe(**updates: object) -> RecipeTemplate:
    value = RecipeTemplate(
        title="Toast",
        description="",
        source=RecipeSource.OTHER,
        original_url="https://creator.example/toast",
        preparation_minutes=5,
        cooking_minutes=10,
        total_minutes=15,
        servings=Decimal("1"),
        servings_basis="stated",
        ingredients=[ingredient("bread", 0)],
        steps=[
            TemplateStep(
                order_index=0,
                instruction="Toast the bread.",
                ingredient_indexes=[0],
            )
        ],
        review_status=RecipeReviewStatus.READY,
        uncertainties=[],
    )
    return value.model_copy(update=updates)


def verifier(model: Model) -> TargetedRecipeVerifier:
    return TargetedRecipeVerifier(
        client=model,
        model_id="quality-verifier",
        max_tokens=2048,
    )


def disputed() -> tuple[RecipeTemplate, list[VerificationEvidence]]:
    return (
        recipe(total_minutes=5),
        [evidence("Prep 5 minutes and cook 10 minutes. Total 15 minutes.")],
    )


def test_clean_recipe_skips_the_verification_model() -> None:
    model = Model()
    value = recipe()

    result = verifier(model).verify(
        value,
        evidence=[evidence("Makes 1 serving. Prep 5 min, cook 10 min, total 15 min.")],
        job_id=uuid4(),
    )

    assert result == value
    assert model.calls == []


def test_verifier_boundary_copies_text_and_excludes_visual_observations() -> None:
    context = AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="youtube",
            platform_video_id="verification-boundary",
            canonical_url="https://www.youtube.com/watch?v=verification-boundary",
            source_revision="1",
        ),
        is_public=True,
        title="Toast",
        description="One slice bread.",
        transcript=[
            TextEvidence(
                text="Toast for five minutes.",
                provenance="caption",
                generated=False,
            )
        ],
        linked_documents=[
            LinkedDocument(
                url="https://creator.example/toast",
                text="Makes one serving.",
                provenance="creator-link",
            )
        ],
        visual_observations=[
            VisualEvidence(
                text="NEVER ENTER THE VERIFIER",
                provenance="legacy-vision",
            )
        ],
    )

    values = verification_evidence(context)

    assert {value.text for value in values} == {
        "Toast",
        "One slice bread.",
        "Toast for five minutes.",
        "Makes one serving.",
    }


def test_detects_serving_basis_mismatch() -> None:
    issues = deterministic_issues(
        recipe(servings=Decimal("1"), servings_basis="unknown"),
        [evidence("This recipe serves 4 people.")],
    )

    assert "servings" in {value.field_path for value in issues}


def test_stated_serving_basis_requires_yield_text() -> None:
    issues = deterministic_issues(recipe(servings_basis="stated"), [])

    assert "servings_basis" in {value.field_path for value in issues}


def test_detects_total_time_arithmetic_contradiction() -> None:
    issues = deterministic_issues(
        recipe(preparation_minutes=10, cooking_minutes=20, total_minutes=15),
        [evidence("Prep 10 minutes. Cook 20 minutes. Total 30 minutes.")],
    )

    assert "total_minutes" in {value.field_path for value in issues}


def test_detects_out_of_bounds_ingredient_reference() -> None:
    invalid_step = TemplateStep.model_construct(
        order_index=0,
        instruction="Toast the bread.",
        ingredient_indexes=[8],
        timers=[],
        source_start_seconds=None,
        source_end_seconds=None,
        uncertainty=None,
    )
    invalid = recipe().model_copy(update={"steps": [invalid_step]})

    issues = deterministic_issues(invalid, [])

    assert issues[0].field_path == "steps[0].ingredient_indexes"


def test_detects_gross_calorie_macro_inconsistency() -> None:
    nutrition = TemplateNutrition(
        calories=Decimal("900"),
        protein_grams=Decimal("1"),
        carbohydrate_grams=Decimal("1"),
        fat_grams=Decimal("1"),
        serving_basis=Decimal("1"),
        is_estimated=False,
        basis="creatorStated",
        evidence="900 calories, 1g protein, 1g carbs, 1g fat.",
    )

    issues = deterministic_issues(recipe(nutrition=nutrition), [])

    assert "nutrition" in {value.field_path for value in issues}


def test_detects_material_ingredient_missing_from_the_method() -> None:
    value = recipe().model_copy(
        update={
            "ingredients": [ingredient("bread", 0), ingredient("butter", 1)],
        }
    )

    issues = deterministic_issues(value, [evidence("Toast the bread with butter.")])

    assert "ingredients[1]" in {value.field_path for value in issues}


def test_detects_conflicting_source_amounts() -> None:
    value = recipe().model_copy(update={"ingredients": [ingredient("sugar", 0)]})

    issues = deterministic_issues(
        value,
        [evidence("Use 1 cup sugar."), evidence("Ingredients: 2 cups sugar.")],
    )

    assert "ingredients[0].normalized_quantity" in {
        value.field_path for value in issues
    }


@pytest.mark.parametrize(
    "value",
    [
        # 13 characters of model output that format(..., "f") would expand
        # to a ~1 GB fixed-point string before any other check ran.
        "1E+1000000000",
        # The negative twin expands to "0.000...1" of the same size.
        "1E-1000000000",
        # Just past the magnitude band on either side.
        "1E+13",
        "1E-13",
        # Just past the length bound: digit-heavy rather than exponent-heavy.
        "9" * 65,
        "NaN",
        "sNaN",
        "Infinity",
        "-Infinity",
    ],
)
def test_untrusted_decimals_outside_the_recipe_band_are_refused(value: str) -> None:
    assert _decimal(value) is None


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("4", Decimal("4")),
        ("2.5", Decimal("2.5")),
        (15, Decimal(15)),
        (" 250 ", Decimal("250")),
        ("1E+12", Decimal("1E+12")),
        ("1E-12", Decimal("1E-12")),
        ("0", Decimal("0")),
        ("-3", Decimal("-3")),
    ],
)
def test_recipe_scale_decimals_still_parse(value: object, expected: Decimal) -> None:
    assert _decimal(value) == expected


def test_model_can_patch_only_a_flagged_field_with_exact_source_support() -> None:
    source = "Makes 1 serving. Prep 5 minutes and cook 10 minutes. Total 15 minutes."
    model = Model(
        patches=[
            VerificationPatch(
                field_path="total_minutes",
                value=15,
                supporting_evidence=source,
            ),
            VerificationPatch(
                field_path="title",
                value="A Different Recipe",
                supporting_evidence=source,
            ),
        ]
    )

    result = verifier(model).verify(
        recipe(total_minutes=5),
        evidence=[evidence(source), evidence("Unrelated autobiography.")],
        job_id=uuid4(),
    )

    assert result.total_minutes == 15
    assert result.title == "Toast"
    assert result.review_status == RecipeReviewStatus.READY
    assert model.calls[0]["evidence"] == [evidence(source)]


def test_model_supplied_exponent_bomb_is_rejected_without_expansion() -> None:
    source = "Serves 4."
    model = Model(
        patches=[
            VerificationPatch(
                field_path="servings",
                value="1E+1000000000",
                supporting_evidence=source,
            )
        ]
    )

    started = time.perf_counter()
    result = verifier(model).verify(
        recipe(),
        evidence=[evidence(source)],
        job_id=uuid4(),
    )

    # Before the bound this line was reached only after two ~1 GB string
    # materializations; the patch itself was rejected either way, which is
    # why the red for this finding lives at the _decimal boundary above.
    assert time.perf_counter() - started < 1.0
    assert result.servings == Decimal("1")
    assert result.review_status == RecipeReviewStatus.NEEDS_REVIEW
    assert "servings" in {value.field for value in result.uncertainties}


def test_patch_with_evidence_not_in_the_source_is_rejected() -> None:
    model = Model(
        patches=[
            VerificationPatch(
                field_path="total_minutes",
                value=15,
                supporting_evidence="Total 15 minutes.",
            )
        ]
    )

    result = verifier(model).verify(
        recipe(total_minutes=5),
        evidence=[evidence("Prep 5 minutes and cook 10 minutes.")],
        job_id=uuid4(),
    )

    assert result.total_minutes == 5
    assert result.review_status == RecipeReviewStatus.NEEDS_REVIEW
    assert "total_minutes" in {value.field for value in result.uncertainties}


def test_unsupported_patch_value_is_rejected() -> None:
    source = "Total 15 minutes."
    model = Model(
        patches=[
            VerificationPatch(
                field_path="total_minutes",
                value="fifteen-ish",
                supporting_evidence=source,
            )
        ]
    )

    result = verifier(model).verify(
        recipe(total_minutes=5),
        evidence=[evidence(source)],
        job_id=uuid4(),
    )

    assert result.total_minutes == 5
    assert result.review_status == RecipeReviewStatus.NEEDS_REVIEW


def test_verification_is_recorded_as_a_distinct_provider_operation() -> None:
    usage = Usage()
    model = Model(cost_usd=Decimal("0.009"))
    service = TargetedRecipeVerifier(
        client=model,
        model_id="quality-verifier",
        max_tokens=2048,
        usage=usage,
        provider="openrouter",
    )
    value, spans = disputed()

    service.verify(value, evidence=spans, job_id=uuid4())

    assert {call["operation"] for call in usage.starts} == {"recipeVerification"}
    assert usage.completions == 1
    assert usage.completion_values["cost_usd"] == Decimal("0.009")
    assert usage.failures == 0


def test_verification_provider_failure_keeps_issues_for_review() -> None:
    class BrokenModel(Model):
        def propose_patches(self, **values: object) -> StructuredVerificationResponse:
            del values
            raise VerificationUnavailable("down")

    usage = Usage()
    value, spans = disputed()
    service = TargetedRecipeVerifier(
        client=BrokenModel(),
        model_id="quality-verifier",
        max_tokens=2048,
        usage=usage,
    )

    result = service.verify(value, evidence=spans, job_id=uuid4())

    assert result.review_status == RecipeReviewStatus.NEEDS_REVIEW
    assert usage.failures == 1


def test_openrouter_verifier_uses_strict_text_only_structured_output() -> None:
    captured: dict[str, object] = {}

    def respond(request: httpx.Request) -> httpx.Response:
        captured["payload"] = request.read().decode()
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": "stop",
                        "message": {
                            "content": (
                                '{"patches":[{"fieldPath":"total_minutes",'
                                '"value":15,"supportingEvidence":"Total 15 minutes."}]}'
                            )
                        },
                    }
                ],
                "usage": {
                    "prompt_tokens": 100,
                    "completion_tokens": 20,
                    "cost": "0.0075",
                },
            },
        )

    client = OpenRouterVerificationClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key="verify-key",
        base_url="https://openrouter.test/api/v1",
    )
    value, spans = disputed()
    issues = deterministic_issues(value, spans)

    result = client.propose_patches(
        model="quality-verifier",
        max_tokens=2048,
        template=value,
        issues=issues,
        evidence=spans,
    )

    assert result.parsed_output is not None
    assert result.parsed_output.patches[0].field_path == "total_minutes"
    assert result.input_tokens == 100
    assert result.cost_usd == Decimal("0.0075")
    payload = str(captured["payload"])
    assert '"name":"recipe_verification"' in payload
    assert "image_url" not in payload
    assert "video_url" not in payload


@pytest.mark.parametrize("status", [401, 429, 503])
def test_openrouter_verifier_provider_errors_are_typed(status: int) -> None:
    client = OpenRouterVerificationClient(
        http=httpx.Client(
            transport=httpx.MockTransport(
                lambda _: httpx.Response(status, json={"error": "down"})
            )
        ),
        api_key="verify-key",
        base_url="https://openrouter.test/api/v1",
    )
    value, spans = disputed()

    with pytest.raises(VerificationUnavailable):
        client.propose_patches(
            model="quality-verifier",
            max_tokens=2048,
            template=value,
            issues=deterministic_issues(value, spans),
            evidence=spans,
        )
