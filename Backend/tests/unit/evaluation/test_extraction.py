import hashlib
import json
from datetime import date
from decimal import Decimal
from pathlib import Path

import pytest

from ladle.acquisition.models import (
    AcquiredVideoContext,
    LinkedDocument,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.evaluation.extraction import (
    EvaluationCorpus,
    IngredientNameQuantity,
    NutritionPrediction,
    NutritionReference,
    StructuralPrediction,
    StructuralReference,
    measure_structure,
    score_nutrition_case,
    summarize_nutrition_cases,
    whole_recipe_prediction,
)
from ladle.extraction.evidence_gate import (
    InsufficientTextEvidence,
    require_recipe_evidence,
)
from ladle.recipes.template_clone import RecipeTemplate, TemplateNutrition

FIXTURES = Path(__file__).parents[2] / "fixtures" / "evaluation"


def _reference(**changes: Decimal) -> NutritionReference:
    values = {
        "servings": Decimal("4"),
        "calories": Decimal("800"),
        "protein_grams": Decimal("40"),
        "carbohydrate_grams": Decimal("80"),
        "fat_grams": Decimal("30"),
    }
    values.update(changes)
    return NutritionReference(**values)


def _prediction(
    *,
    basis: str = "usdaCalculated",
    **changes: Decimal,
) -> NutritionPrediction:
    values = _reference().model_dump()
    values.update(changes)
    return NutritionPrediction(**values, basis=basis)


def test_missing_nutrition_fails() -> None:
    score = score_nutrition_case(_reference(), None)

    assert not score.passes
    assert score.failed_fields == ["nutrition"]


def test_incorrect_serving_count_fails() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(servings=Decimal("5")),
    )

    assert not score.passes
    assert score.failed_fields == ["servings"]


def test_calories_outside_ten_percent_fail() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(calories=Decimal("881")),
    )

    assert not score.passes
    assert score.failed_fields == ["calories"]


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("protein_grams", Decimal("44.1")),
        ("carbohydrate_grams", Decimal("88.1")),
        ("fat_grams", Decimal("33.1")),
    ],
)
def test_each_macro_outside_larger_of_two_grams_or_ten_percent_fails(
    field: str,
    value: Decimal,
) -> None:
    score = score_nutrition_case(_reference(), _prediction(**{field: value}))

    assert not score.passes
    assert score.failed_fields == [field]


def test_small_macro_uses_two_gram_absolute_tolerance() -> None:
    reference = _reference(protein_grams=Decimal("5"))

    inside = score_nutrition_case(
        reference,
        _prediction(protein_grams=Decimal("7")),
    )
    outside = score_nutrition_case(
        reference,
        _prediction(protein_grams=Decimal("7.1")),
    )

    assert inside.passes
    assert outside.failed_fields == ["protein_grams"]


def test_all_nutrition_fields_must_pass_together() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(
            calories=Decimal("900"),
            protein_grams=Decimal("50"),
        ),
    )

    assert not score.passes
    assert score.failed_fields == ["calories", "protein_grams"]


def test_unknown_basis_fails_even_when_numbers_match() -> None:
    score = score_nutrition_case(_reference(), _prediction(basis="unknown"))

    assert not score.passes
    assert score.failed_fields == ["basis"]


def test_expected_nutrition_basis_is_part_of_the_case_gate() -> None:
    score = score_nutrition_case(
        _reference(),
        _prediction(basis="creatorStated"),
        expected_basis="usdaCalculated",
    )

    assert score.failed_fields == ["basis"]


def test_prediction_is_normalized_from_serving_basis_to_whole_recipe() -> None:
    template = RecipeTemplate(
        title="Dinner",
        description="",
        source=RecipeSource.OTHER,
        original_url="https://example.com/dinner",
        servings=Decimal("4"),
        servings_basis="stated",
        ingredients=[],
        steps=[],
        nutrition=TemplateNutrition(
            calories=Decimal("500"),
            protein_grams=Decimal("20"),
            carbohydrate_grams=Decimal("60"),
            fat_grams=Decimal("18"),
            serving_basis=Decimal("1"),
            is_estimated=False,
            basis="creatorStated",
        ),
        review_status=RecipeReviewStatus.READY,
    )

    prediction = whole_recipe_prediction(template)

    assert prediction is not None
    assert prediction.servings == Decimal("4")
    assert prediction.calories == Decimal("2000")
    assert prediction.protein_grams == Decimal("80")
    assert prediction.carbohydrate_grams == Decimal("240")
    assert prediction.fat_grams == Decimal("72")


def test_prediction_refuses_unknown_yield_or_incomplete_nutrition() -> None:
    template = RecipeTemplate(
        title="Dinner",
        description="",
        source=RecipeSource.OTHER,
        original_url="https://example.com/dinner",
        servings=Decimal("1"),
        servings_basis="unknown",
        ingredients=[],
        steps=[],
        nutrition=None,
        review_status=RecipeReviewStatus.NEEDS_REVIEW,
    )

    assert whole_recipe_prediction(template) is None


def test_nutrition_suite_gate_requires_at_least_ninety_five_percent() -> None:
    passing = score_nutrition_case(_reference(), _prediction())
    failing = score_nutrition_case(_reference(), None)

    below_gate = summarize_nutrition_cases([passing] * 18 + [failing, failing])
    at_gate = summarize_nutrition_cases([passing] * 19 + [failing])

    assert below_gate.pass_rate == Decimal("0.9")
    assert not below_gate.meets_gate
    assert at_gate.pass_rate == Decimal("0.95")
    assert at_gate.meets_gate


def test_structural_measurements_are_reported_separately() -> None:
    reference = StructuralReference(
        stated_cook_time_minutes=Decimal("30"),
        ingredient_name_quantities=[
            IngredientNameQuantity(name="olive oil", quantity="2 tbsp"),
            IngredientNameQuantity(name="chickpeas", quantity="1 can"),
        ],
        ordered_step_phrases=["heat the oil", "add the chickpeas", "simmer"],
    )
    prediction = StructuralPrediction(
        stated_cook_time_minutes=Decimal("25"),
        ingredient_name_quantities=[
            IngredientNameQuantity(name="Olive Oil", quantity="2 TBSP"),
        ],
        steps=["Heat the oil.", "Simmer until thick."],
    )

    measured = measure_structure(reference, prediction)

    assert not measured.cook_time_matches
    assert measured.ingredient_pairs_matched == 1
    assert measured.ingredient_pairs_total == 2
    assert measured.ordered_step_phrases_matched == 2
    assert measured.ordered_step_phrases_total == 3


def _fixture(filename: str) -> tuple[dict[str, object], EvaluationCorpus]:
    raw = json.loads((FIXTURES / filename).read_text())
    return raw, EvaluationCorpus.model_validate(raw)


def _digest(raw: dict[str, object]) -> str:
    content = {
        "cases": raw["cases"],
        "safetyCases": raw.get("safetyCases", []),
    }
    encoded = json.dumps(
        content,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def test_checked_in_reference_corpora_are_verified_and_complete() -> None:
    tuning_raw, tuning = _fixture("text-only-tuning.json")
    held_raw, held = _fixture("text-only-held-out.json")

    assert tuning.partition == "tuning"
    assert held.partition == "heldOut"
    assert tuning.reference_status == held.reference_status == "verified"
    assert len(tuning.cases) >= 20
    assert len(held.cases) >= 80
    assert len(held.safety_cases) >= 20
    assert tuning.corpus_digest == _digest(tuning_raw)
    assert held.corpus_digest == _digest(held_raw)


def test_reference_corpora_have_no_identity_overlap_and_supported_sources() -> None:
    _, tuning = _fixture("text-only-tuning.json")
    _, held = _fixture("text-only-held-out.json")
    all_cases = [*tuning.cases, *held.cases]

    assert len({case.id for case in all_cases}) == len(all_cases)
    assert len({case.cache_key for case in all_cases}) == len(all_cases)
    assert len({case.source_url for case in all_cases}) == len(all_cases)
    assert {case.expected_nutrition_basis for case in all_cases} == {
        "creatorStated",
        "usdaCalculated",
    }
    assert all(case.license == "usGovernmentPublicDomain" for case in all_cases)
    assert all(case.retrieved_at <= date(2026, 8, 24) for case in all_cases)


def test_sparse_safety_corpus_is_locked_and_expects_safe_refusal() -> None:
    _, held = _fixture("text-only-held-out.json")

    assert len({case.id for case in held.safety_cases}) == len(held.safety_cases)
    assert all(
        case.expected_outcome == "insufficientTextEvidence"
        for case in held.safety_cases
    )
    assert all(case.license == "synthetic" for case in held.safety_cases)


#: The one safety case the gate no longer refuses, kept explicit rather than
#: quietly dropped. "No measurements, I cook with my heart." carries no
#: ingredients and no method, but the word "cook" satisfies has_instructions.
#: It survived only because the old three-quantity threshold caught it, and
#: that threshold was rejecting far more real recipes than junk like this.
#: It now reaches the extractor, which has nothing to build from and marks
#: the result for human review instead of publishing it.
_GATE_ADMITS_DESPITE_BEING_SPARSE = {"safety-no-match-013"}


def test_sparse_safety_corpus_is_refused_by_the_production_evidence_gate() -> None:
    _, held = _fixture("text-only-held-out.json")
    admitted: list[str] = []

    for index, case in enumerate(held.safety_cases):
        context = AcquiredVideoContext(
            source=SourceVideoDescriptor(
                sourceVideoID="00000000-0000-4000-8000-000000000001",
                platform="youtube",
                platformVideoID=f"safety-{index}",
                canonicalURL=case.source_url,
                sourceRevision="fixture-v1",
            ),
            isPublic=True,
            title=case.evidence.title,
            description=case.evidence.description,
            transcript=[
                TextEvidence(
                    text=value,
                    provenance="synthetic-transcript",
                    generated=False,
                )
                for value in case.evidence.transcript
            ],
            linkedDocuments=[
                LinkedDocument(
                    url=case.source_url,
                    text=value,
                    provenance="synthetic-linked-document",
                )
                for value in case.evidence.linked_document_texts
            ],
            visualObservations=[],
        )

        try:
            require_recipe_evidence(context)
        except InsufficientTextEvidence:
            continue
        admitted.append(case.id)

    assert admitted == sorted(_GATE_ADMITS_DESPITE_BEING_SPARSE), (
        "the sparse safety corpus changed which cases the gate lets through; "
        "every admission has to be a deliberate, recorded decision"
    )
