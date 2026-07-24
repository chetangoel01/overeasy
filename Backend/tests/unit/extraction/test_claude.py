from dataclasses import dataclass, field
from decimal import Decimal
from uuid import uuid4

import pytest

from ladle.acquisition.models import (
    AcquiredVideoContext,
    SourceVideoDescriptor,
)
from ladle.extraction.claude import (
    ClaudeRecipeExtractor,
    ClaudeStructuredResponse,
    ExtractionRefused,
    ExtractionTruncated,
)
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedStep,
    RecipeExtraction,
)


@dataclass
class FakeClaude:
    response: ClaudeStructuredResponse | Exception
    calls: list[dict[str, object]] = field(default_factory=list)

    def parse_recipe(
        self,
        *,
        model: str,
        max_tokens: int,
        system: str,
        user_prompt: str,
    ) -> ClaudeStructuredResponse:
        self.calls.append(
            {
                "model": model,
                "max_tokens": max_tokens,
                "system": system,
                "user_prompt": user_prompt,
            }
        )
        if isinstance(self.response, Exception):
            raise self.response
        return self.response


def context() -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="instagram",
            platform_video_id="claude-test",
            canonical_url="https://www.instagram.com/reel/claude-test",
            source_revision="1",
        ),
        is_public=True,
        title="Toast",
        description="",
        transcript=[],
        visual_observations=[],
        diagnostics=[],
    )


def extracted() -> RecipeExtraction:
    return RecipeExtraction(
        title="Toast",
        description="",
        creator_name=None,
        servings=Decimal("1"),
        ingredients=[
            ExtractedIngredient(
                name="bread",
                quantity_text="1 slice",
                normalized_quantity=Decimal("1"),
                unit="slice",
                confidence=0.95,
            )
        ],
        steps=[
            ExtractedStep(
                instruction="Toast the bread.",
                ingredient_indices=[0],
                confidence=0.95,
            )
        ],
        uncertainties=[],
    )


def extractor(
    response: ClaudeStructuredResponse | Exception,
) -> ClaudeRecipeExtractor:
    return ClaudeRecipeExtractor(
        client=FakeClaude(response),
        model_id="claude-sonnet-4-6",
        max_tokens=4096,
    )


def test_structured_output_converts_to_validated_template() -> None:
    service = extractor(
        ClaudeStructuredResponse(
            stop_reason="end_turn",
            parsed_output=extracted(),
            input_tokens=100,
            output_tokens=50,
        )
    )

    result = service.extract(context(), job_id=uuid4())

    assert result.title == "Toast"
    assert result.steps[0].ingredient_indexes == [0]
    assert service.contract_version == "v1"
    assert service.prompt_version


@pytest.mark.parametrize(
    ("stop_reason", "error_type"),
    [
        ("refusal", ExtractionRefused),
        ("max_tokens", ExtractionTruncated),
    ],
)
def test_stop_reason_is_checked_before_parsed_output(
    stop_reason: str,
    error_type: type[Exception],
) -> None:
    service = extractor(
        ClaudeStructuredResponse(
            stop_reason=stop_reason,
            parsed_output=extracted(),
            input_tokens=100,
            output_tokens=50,
        )
    )

    with pytest.raises(error_type):
        service.extract(context(), job_id=uuid4())


def test_missing_parsed_output_is_malformed() -> None:
    from ladle.extraction.claude import MalformedExtraction

    service = extractor(
        ClaudeStructuredResponse(
            stop_reason="end_turn",
            parsed_output=None,
            input_tokens=100,
            output_tokens=10,
        )
    )

    with pytest.raises(MalformedExtraction):
        service.extract(context(), job_id=uuid4())


def test_timeout_is_typed_as_unavailable() -> None:
    from ladle.extraction.claude import ExtractionUnavailable

    service = extractor(TimeoutError())

    with pytest.raises(ExtractionUnavailable):
        service.extract(context(), job_id=uuid4())
