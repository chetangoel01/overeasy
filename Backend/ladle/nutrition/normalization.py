"""Model-assisted normalization for deterministic USDA nutrition."""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Any, Protocol
from uuid import UUID

import httpx
from pydantic import Field, ValidationError

from ladle.acquisition.models import AcquiredVideoContext
from ladle.contracts.common import WireModel
from ladle.contracts.recipes import FieldUncertaintyDTO
from ladle.recipes.template_clone import RecipeTemplate
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink


class NutritionNormalizationUnavailable(Exception):
    """The recipe could not be normalized into a complete USDA input."""


class NormalizedIngredient(WireModel):
    ingredient_index: int = Field(ge=0)
    usda_search_term: str = Field(min_length=1, max_length=200)
    grams: Decimal = Field(gt=0)
    was_inferred: bool
    rationale: str = Field(min_length=1, max_length=500)


class NutritionNormalization(WireModel):
    servings: Decimal = Field(gt=0)
    servings_confidence: Decimal = Field(ge=0, le=1)
    servings_rationale: str = Field(min_length=1, max_length=1_000)
    ingredients: list[NormalizedIngredient]
    excluded_ingredient_indexes: list[int] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list, max_length=20)


@dataclass(frozen=True)
class NutritionNormalizationResponse:
    parsed_output: NutritionNormalization | None
    input_tokens: int
    output_tokens: int
    cost_usd: Decimal | None


@dataclass(frozen=True)
class NormalizedRecipe:
    template: RecipeTemplate
    servings_confidence: Decimal
    servings_rationale: str
    assumptions: tuple[str, ...]


class NutritionNormalizationClient(Protocol):
    def normalize(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        context: AcquiredVideoContext,
    ) -> NutritionNormalizationResponse: ...


_SYSTEM_PROMPT = """You normalize recipes for a deterministic USDA calculation.
Use only the supplied creator evidence and reviewed recipe. Preserve creator-stated
servings and raw quantities. When yield or an amount is missing, make a conservative
culinary estimate and expose it. Convert every energy-bearing ingredient to grams,
including liquids by applying a reasonable density. Use a short generic USDA search
term. Exclude only water and genuinely nutritionally immaterial to-taste ingredients.
Return no nutrient totals. Never hide an assumption."""


class OpenRouterNutritionNormalizationClient:
    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: str,
        base_url: str,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._sleep = sleep

    def normalize(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        context: AcquiredVideoContext,
    ) -> NutritionNormalizationResponse:
        schema = NutritionNormalization.model_json_schema()
        payload = {
            "model": model,
            "max_tokens": max_tokens,
            "temperature": 0,
            "provider": {"require_parameters": True},
            "messages": [
                {"role": "system", "content": _SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": json.dumps(
                        _normalization_input(template, context),
                        ensure_ascii=False,
                    ),
                },
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "nutrition_normalization",
                    "strict": True,
                    "schema": schema,
                },
            },
        }
        response: httpx.Response | None = None
        for attempt in range(2):
            try:
                response = self._http.post(
                    f"{self._base_url}/chat/completions",
                    headers={
                        "Authorization": f"Bearer {self._api_key}",
                        "X-Title": "Ladle",
                    },
                    json=payload,
                )
            except httpx.HTTPError as error:
                raise NutritionNormalizationUnavailable(
                    "OpenRouter nutrition normalization unavailable"
                ) from error
            if response.status_code != 429 or attempt == 1:
                break
            self._sleep(2)
        assert response is not None
        if response.status_code >= 400:
            raise NutritionNormalizationUnavailable(
                "OpenRouter nutrition normalization failed with "
                f"HTTP {response.status_code}"
            )
        try:
            data = response.json()
            content = data["choices"][0]["message"]["content"]
            parsed = NutritionNormalization.model_validate_json(content)
        except (json.JSONDecodeError, LookupError, TypeError, ValidationError) as error:
            raise NutritionNormalizationUnavailable(
                "OpenRouter returned invalid nutrition normalization"
            ) from error
        usage = data.get("usage") or {}
        return NutritionNormalizationResponse(
            parsed_output=parsed,
            input_tokens=int(usage.get("prompt_tokens") or 0),
            output_tokens=int(usage.get("completion_tokens") or 0),
            cost_usd=_cost(usage.get("cost")),
        )


def _normalization_input(
    template: RecipeTemplate,
    context: AcquiredVideoContext,
) -> dict[str, Any]:
    return {
        "sourceURL": template.original_url,
        "title": context.title,
        "description": context.description,
        "transcript": [item.text for item in context.transcript],
        "linkedDocuments": [item.text for item in context.linked_documents],
        "recipe": template.model_dump(mode="json", exclude={"nutrition"}),
    }


def _cost(value: object) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        result = Decimal(str(value))
    except InvalidOperation:
        return None
    return result if result.is_finite() and result >= 0 else None


class RecipeNutritionNormalizer:
    def __init__(
        self,
        *,
        client: NutritionNormalizationClient,
        model_id: str,
        max_tokens: int,
        usage: ProviderUsageSink | None = None,
        provider: str = "openrouter",
    ) -> None:
        self._client = client
        self._model_id = model_id
        self._max_tokens = max_tokens
        self._usage = usage or NullProviderUsageSink()
        self._provider = provider

    def normalize(
        self,
        template: RecipeTemplate,
        *,
        context: AcquiredVideoContext,
        job_id: UUID,
    ) -> NormalizedRecipe:
        key = f"{self._provider}:nutrition-normalize:v1:{self._model_id}"
        self._usage.started(
            job_id=job_id,
            provider=self._provider,
            operation="nutritionNormalization",
            idempotency_key=key,
            external_job_id=None,
            billed_units=Decimal(0),
        )
        try:
            response = self._client.normalize(
                model=self._model_id,
                max_tokens=self._max_tokens,
                template=template,
                context=context,
            )
            value = response.parsed_output
            if value is None:
                raise NutritionNormalizationUnavailable(
                    "normalizer returned no structured output"
                )
            self._validate_coverage(template, value)
        except Exception as error:
            self._usage.failed(
                job_id=job_id,
                idempotency_key=key,
                failure_code=type(error).__name__,
            )
            if isinstance(error, NutritionNormalizationUnavailable):
                raise
            raise NutritionNormalizationUnavailable(
                "nutrition normalization unavailable"
            ) from error

        by_index = {item.ingredient_index: item for item in value.ingredients}
        excluded = set(value.excluded_ingredient_indexes)
        ingredients = []
        for index, ingredient in enumerate(template.ingredients):
            normalized = by_index.get(index)
            if normalized is None:
                ingredients.append(
                    ingredient.model_copy(
                        update={"exclude_from_nutrition": index in excluded}
                    )
                )
                continue
            uncertainty = ingredient.uncertainty
            if normalized.was_inferred:
                uncertainty = FieldUncertaintyDTO(
                    field=f"ingredients[{index}].nutritionAmount",
                    reason=normalized.rationale,
                )
            ingredients.append(
                ingredient.model_copy(
                    update={
                        "metric_amount": normalized.grams,
                        "metric_unit": "g",
                        "usda_search_term": normalized.usda_search_term,
                        "is_to_taste": False,
                        "exclude_from_nutrition": False,
                        "uncertainty": uncertainty,
                    }
                )
            )

        stated = template.servings_basis == "stated"
        servings = template.servings if stated else value.servings
        confidence = Decimal(1) if stated else value.servings_confidence
        uncertainties = [
            item for item in template.uncertainties if item.field != "servings"
        ]
        if not stated:
            uncertainties.append(
                FieldUncertaintyDTO(
                    field="servings",
                    reason=value.servings_rationale,
                    confidence=float(value.servings_confidence),
                )
            )
        updated = template.model_copy(
            update={
                "servings": servings,
                "servings_basis": ("stated" if stated else "estimatedFromYield"),
                "ingredients": ingredients,
                "uncertainties": uncertainties,
            }
        )
        self._usage.completed(
            job_id=job_id,
            idempotency_key=key,
            billed_units=Decimal(1),
            latency_ms=None,
            cost_usd=response.cost_usd,
        )
        return NormalizedRecipe(
            template=updated,
            servings_confidence=confidence,
            servings_rationale=(
                "Creator stated the serving count."
                if stated
                else value.servings_rationale
            ),
            assumptions=tuple(value.assumptions),
        )

    @staticmethod
    def _validate_coverage(
        template: RecipeTemplate,
        value: NutritionNormalization,
    ) -> None:
        normalized = [item.ingredient_index for item in value.ingredients]
        excluded = value.excluded_ingredient_indexes
        all_indexes = normalized + excluded
        if len(all_indexes) != len(set(all_indexes)):
            raise NutritionNormalizationUnavailable(
                "normalizer returned duplicate ingredient indexes"
            )
        if any(index >= len(template.ingredients) for index in all_indexes):
            raise NutritionNormalizationUnavailable(
                "normalizer returned an unknown ingredient index"
            )
        material = {
            index
            for index, ingredient in enumerate(template.ingredients)
            if not ingredient.is_to_taste
        }
        if not material <= set(all_indexes):
            raise NutritionNormalizationUnavailable(
                "normalizer did not account for every material ingredient"
            )
