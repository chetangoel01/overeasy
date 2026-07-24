import os
from uuid import uuid4

import pytest
from anthropic import Anthropic

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
    TextEvidence,
)
from ladle.extraction.claude import (
    AnthropicStructuredClient,
    ClaudeRecipeExtractor,
)


@pytest.mark.live_provider
def test_claude_structured_recipe_capability() -> None:
    key = os.environ.get("LADLE_ANTHROPIC_API_KEY")
    if not key:
        pytest.skip("LADLE_ANTHROPIC_API_KEY is not configured")
    extractor = ClaudeRecipeExtractor(
        client=AnthropicStructuredClient(Anthropic(api_key=key, timeout=60)),
        model_id=os.environ.get(
            "LADLE_ANTHROPIC_MODEL_ID",
            "claude-sonnet-4-6",
        ),
        max_tokens=4096,
    )
    context = AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="youtube",
            platform_video_id="live-structured-smoke",
            canonical_url="https://www.youtube.com/watch?v=live-structured-smoke",
            source_revision="live",
        ),
        is_public=True,
        title="Garlic Toast",
        description="One slice of bread with one teaspoon butter.",
        transcript=[
            TextEvidence(
                text="Spread one teaspoon butter on one slice bread and toast.",
                start_seconds=0,
                end_seconds=4,
                provenance="live-smoke-fixture",
                generated=False,
            )
        ],
        visual_observations=[],
        diagnostics=[],
    )

    template = extractor.extract(context, job_id=uuid4())

    assert template.ingredients
    assert template.steps
