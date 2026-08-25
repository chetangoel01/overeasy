from uuid import uuid4

from ladle.acquisition.coverage import assess_coverage
from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
    VisualEvidence,
)


def context(
    transcript: str,
    *,
    visuals: list[str] | None = None,
) -> AcquiredVideoContext:
    source = SourceVideoDescriptor(
        source_video_id=uuid4(),
        platform="youtube",
        platform_video_id="coverage-test",
        canonical_url="https://www.youtube.com/watch?v=coverage-test",
        source_revision="1",
    )
    return AcquiredVideoContext(
        source=source,
        is_public=True,
        title="Recipe",
        description="",
        transcript=[
            TextEvidence(
                text=transcript,
                start_seconds=0,
                end_seconds=10,
                provenance="native",
                generated=False,
            )
        ],
        visual_observations=[
            VisualEvidence(
                text=value,
                timestamp_seconds=float(index),
                provenance="visual",
                confidence=0.9,
            )
            for index, value in enumerate(visuals or [])
        ],
        diagnostics=[],
    )


def test_recipe_like_quantities_and_ordered_actions_are_sufficient() -> None:
    report = assess_coverage(
        context("Add 2 cups flour and 1 teaspoon salt. Mix, then bake for 20 minutes.")
    )

    assert report.has_quantities
    assert report.has_instructions
    assert report.sufficient_for_extraction


def test_platform_published_text_can_complete_sparse_speech() -> None:
    sparse = context(
        "Add the flour and salt. Mix everything, then bake until golden.",
        visuals=["2 cups flour", "1 teaspoon salt"],
    )

    report = assess_coverage(sparse)

    assert report.has_quantities
    assert report.has_instructions
    assert report.sufficient_for_extraction


def test_missing_quantities_requires_review() -> None:
    report = assess_coverage(
        context("Add the flour and salt. Mix everything, then bake until golden.")
    )

    assert not report.has_quantities
    assert report.requires_review
