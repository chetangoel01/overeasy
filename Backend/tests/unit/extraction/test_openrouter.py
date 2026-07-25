import json
from decimal import Decimal

import httpx
import pytest

from ladle.extraction.claude import ExtractionUnavailable
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedStep,
    RecipeExtraction,
)
from ladle.extraction.openrouter import OpenRouterStructuredClient


def extraction_json() -> str:
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
    ).model_dump_json(by_alias=True)


def client_returning(handler) -> OpenRouterStructuredClient:
    return OpenRouterStructuredClient(
        http=httpx.Client(transport=httpx.MockTransport(handler)),
        api_key="test-key",
        base_url="https://openrouter.test/api/v1",
    )


def completion(
    content: str,
    *,
    finish_reason: str = "stop",
) -> httpx.Response:
    return httpx.Response(
        200,
        json={
            "choices": [
                {
                    "finish_reason": finish_reason,
                    "message": {"content": content},
                }
            ],
            "usage": {"prompt_tokens": 120, "completion_tokens": 45},
        },
    )


def parse(client: OpenRouterStructuredClient):
    return client.parse_recipe(
        model="anthropic/claude-sonnet-4.5",
        max_tokens=4096,
        system="system prompt",
        user_prompt="user prompt",
    )


def test_valid_completion_parses_and_reports_usage() -> None:
    captured: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        captured["headers"] = request.headers
        captured["payload"] = json.loads(request.content)
        return completion(extraction_json())

    response = parse(client_returning(handler))

    assert response.parsed_output is not None
    assert response.parsed_output.title == "Toast"
    assert response.stop_reason == "end_turn"
    assert response.input_tokens == 120
    assert response.output_tokens == 45
    assert captured["headers"]["authorization"] == "Bearer test-key"
    schema = captured["payload"]["response_format"]["json_schema"]
    assert schema["name"] == "recipe_extraction"


def test_length_finish_reason_maps_to_max_tokens() -> None:
    response = parse(
        client_returning(lambda request: completion("{", finish_reason="length"))
    )
    assert response.stop_reason == "max_tokens"
    assert response.parsed_output is None


def test_schema_drift_yields_none_parsed_output() -> None:
    response = parse(
        client_returning(lambda request: completion('{"title": "missing everything"}'))
    )
    assert response.stop_reason == "end_turn"
    assert response.parsed_output is None


def test_server_error_raises_extraction_unavailable() -> None:
    with pytest.raises(ExtractionUnavailable):
        parse(
            client_returning(
                lambda request: httpx.Response(503, json={"error": "down"})
            )
        )


def test_transport_error_raises_extraction_unavailable() -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectTimeout("boom", request=request)

    with pytest.raises(ExtractionUnavailable):
        parse(client_returning(handler))
