import json
from decimal import Decimal
from uuid import uuid4

import httpx
import pytest

from ladle.acquisition.models import AcquiredVideoContext, SourceVideoDescriptor
from ladle.contracts.recipes import RecipeReviewStatus, RecipeSource
from ladle.nutrition.normalization import (
    NormalizedIngredient,
    NutritionNormalization,
    NutritionNormalizationUnavailable,
    OpenRouterNutritionNormalizationClient,
)
from ladle.recipes.template_clone import RecipeTemplate, TemplateIngredient


def context() -> AcquiredVideoContext:
    return AcquiredVideoContext(
        source=SourceVideoDescriptor(
            source_video_id=uuid4(),
            platform="tiktok",
            platform_video_id="7612708181004799263",
            canonical_url=(
                "https://www.tiktok.com/@cook/video/7612708181004799263"
            ),
            source_revision="1",
        ),
        is_public=True,
        title="Garlic noodles",
        description="14 oz noodles, sauce, and oil. Serves four.",
    )


def template() -> RecipeTemplate:
    return RecipeTemplate(
        title="Garlic Noodles",
        description="",
        source=RecipeSource.TIKTOK,
        original_url="https://www.tiktok.com/@cook/video/7612708181004799263",
        servings=Decimal(1),
        servings_basis="estimatedFromYield",
        ingredients=[
            TemplateIngredient(
                quantity_text="14 oz",
                normalized_quantity="14",
                unit="oz",
                name="noodles",
                order_index=0,
            )
        ],
        steps=[],
        review_status=RecipeReviewStatus.READY,
    )


def normalization_json() -> str:
    return NutritionNormalization(
        servings=4,
        servings_confidence=Decimal("0.95"),
        servings_rationale="Four portions from fourteen ounces.",
        ingredients=[
            NormalizedIngredient(
                ingredient_index=0,
                usda_search_term="egg noodles dry",
                grams=Decimal("396.9"),
                was_inferred=False,
                rationale="Direct conversion.",
            )
        ],
        assumptions=[],
    ).model_dump_json(by_alias=True)


def completion(*, status: int = 200) -> httpx.Response:
    return httpx.Response(
        status,
        json={
            "choices": [
                {
                    "finish_reason": "stop",
                    "message": {"content": normalization_json()},
                }
            ],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 200,
                "cost": 0.01,
            },
        },
    )


def test_requests_grams_and_never_model_generated_calories() -> None:
    captured: list[dict[str, object]] = []

    def respond(request: httpx.Request) -> httpx.Response:
        captured.append(json.loads(request.content))
        return completion()

    client = OpenRouterNutritionNormalizationClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key="secret-key",
        base_url="https://openrouter.example/api/v1",
    )

    result = client.normalize(
        model="google/gemini-3.7-flash",
        max_tokens=5000,
        template=template(),
        context=context(),
    )

    assert result.parsed_output is not None
    assert result.parsed_output.ingredients[0].grams == Decimal("396.9")
    payload = captured[0]
    assert payload["model"] == "google/gemini-3.7-flash"
    assert payload["temperature"] == 0
    schema = payload["response_format"]["json_schema"]["schema"]  # type: ignore[index]
    serialized = json.dumps(schema)
    assert '"grams"' in serialized
    assert "servingsConfidence" in serialized
    assert "calories" not in serialized
    assert "protein" not in serialized
    assert "secret-key" not in json.dumps(payload)


def test_retries_one_429_then_succeeds() -> None:
    calls = 0
    sleeps: list[float] = []

    def respond(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(429) if calls == 1 else completion()

    client = OpenRouterNutritionNormalizationClient(
        http=httpx.Client(transport=httpx.MockTransport(respond)),
        api_key="secret-key",
        base_url="https://openrouter.example/api/v1",
        sleep=sleeps.append,
    )

    result = client.normalize(
        model="google/gemini-3.7-flash",
        max_tokens=5000,
        template=template(),
        context=context(),
    )

    assert result.parsed_output is not None
    assert calls == 2
    assert sleeps == [2]


def test_second_429_is_typed_and_does_not_expose_key() -> None:
    client = OpenRouterNutritionNormalizationClient(
        http=httpx.Client(
            transport=httpx.MockTransport(lambda _request: httpx.Response(429))
        ),
        api_key="secret-key",
        base_url="https://openrouter.example/api/v1",
        sleep=lambda _seconds: None,
    )

    with pytest.raises(NutritionNormalizationUnavailable) as error:
        client.normalize(
            model="google/gemini-3.7-flash",
            max_tokens=5000,
            template=template(),
            context=context(),
        )

    assert "HTTP 429" in str(error.value)
    assert "secret-key" not in str(error.value)
