"""Strict FoodData Central client for complete calorie and macro records."""

import json
import re
from decimal import Decimal, InvalidOperation
from typing import Literal, Protocol

import httpx
from pydantic import Field

from ladle.acquisition.errors import (
    MalformedProviderResponse,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
)
from ladle.contracts.common import WireDecimal, WireModel

FoodDataType = Literal["Foundation", "SR Legacy", "Survey (FNDDS)", "Branded"]
_DATA_TYPES: tuple[FoodDataType, ...] = (
    "Foundation",
    "SR Legacy",
    "Survey (FNDDS)",
    "Branded",
)
_DATA_TYPE_PRIORITY: dict[object, int] = {
    value: index for index, value in enumerate(_DATA_TYPES)
}
_ENERGY_IDS = (2048, 2047, 1008)
_MACRO_IDS = {"protein": 1003, "fat": 1004, "carbohydrate": 1005}


class _FoodDetailNotFound(Exception):
    pass


class FoodPortion(WireModel):
    amount: WireDecimal = Field(gt=0)
    gram_weight: WireDecimal = Field(gt=0)
    measure_unit: str = Field(min_length=1)
    modifier: str | None = None
    description: str | None = None


class FoodNutrients(WireModel):
    fdc_id: int = Field(gt=0)
    description: str = Field(min_length=1)
    data_type: FoodDataType
    calories_per_100g: WireDecimal = Field(ge=0)
    protein_grams_per_100g: WireDecimal = Field(ge=0)
    carbohydrate_grams_per_100g: WireDecimal = Field(ge=0)
    fat_grams_per_100g: WireDecimal = Field(ge=0)
    portions: list[FoodPortion] = Field(default_factory=list)
    search_rank: int | None = Field(default=None, ge=0)


class FoodDataSource(Protocol):
    def candidates(self, query: str) -> list[FoodNutrients]: ...


class USDAClient:
    """Fetch and cache complete generic-food records from FoodData Central."""

    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: str,
        base_url: str,
        maximum_candidates: int = 5,
    ) -> None:
        if not api_key.strip():
            raise ValueError("USDA API key must not be blank")
        if maximum_candidates < 1:
            raise ValueError("maximum candidates must be positive")
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._maximum_candidates = maximum_candidates
        self._cache: dict[str, tuple[FoodNutrients, ...]] = {}

    def candidates(self, query: str) -> list[FoodNutrients]:
        normalized = _normalize(query)
        if not normalized:
            return []
        cached = self._cache.get(normalized)
        if cached is not None:
            return list(cached)

        response = self._request(
            "POST",
            "/foods/search",
            json={
                "query": normalized,
                "dataType": list(_DATA_TYPES),
                "pageSize": self._maximum_candidates,
            },
        )
        payload = self._json_object(response, "search")
        rows = payload.get("foods")
        if not isinstance(rows, list):
            raise MalformedProviderResponse("USDA search returned invalid foods")

        ranked = sorted(
            (row for row in rows if isinstance(row, dict)),
            key=lambda row: self._search_rank(normalized, row),
        )[: self._maximum_candidates]
        foods: list[FoodNutrients] = []
        for search_rank, row in enumerate(ranked):
            fdc_id = row.get("fdcId")
            if not isinstance(fdc_id, int) or fdc_id <= 0:
                continue
            try:
                detail_response = self._request("GET", f"/food/{fdc_id}")
            except _FoodDetailNotFound:
                continue
            detail = self._json_object(detail_response, "food detail")
            parsed = self._parse_food(detail)
            if parsed is not None:
                foods.append(parsed.model_copy(update={"search_rank": search_rank}))

        value = tuple(foods)
        self._cache[normalized] = value
        return list(value)

    def _request(
        self,
        method: str,
        path: str,
        *,
        json: object | None = None,
    ) -> httpx.Response:
        try:
            response = self._http.request(
                method,
                f"{self._base_url}{path}",
                params={"api_key": self._api_key},
                json=json,
            )
        except httpx.HTTPError as error:
            raise ProviderTransientError("USDA transport unavailable") from error
        if response.status_code in {401, 403}:
            raise ProviderAuthenticationError("USDA authentication failed")
        if response.status_code in {402, 429}:
            raise ProviderQuotaError("USDA quota unavailable")
        if response.status_code == 404 and path.startswith("/food/"):
            raise _FoodDetailNotFound
        if response.status_code >= 400:
            raise ProviderTransientError(
                f"USDA request failed with HTTP {response.status_code}"
            )
        return response

    @staticmethod
    def _json_object(response: httpx.Response, label: str) -> dict[str, object]:
        try:
            value = response.json()
        except (json.JSONDecodeError, ValueError) as error:
            raise MalformedProviderResponse(
                f"USDA {label} returned malformed JSON"
            ) from error
        if not isinstance(value, dict):
            raise MalformedProviderResponse(
                f"USDA {label} returned a non-object response"
            )
        return value

    @staticmethod
    def _search_rank(query: str, row: dict[object, object]) -> tuple[object, ...]:
        description = _normalize(str(row.get("description", "")))
        query_tokens = set(query.split())
        matches = len(query_tokens & set(description.split()))
        data_type = row.get("dataType")
        priority = _DATA_TYPE_PRIORITY.get(data_type, len(_DATA_TYPES))
        raw_score = row.get("score")
        score = float(raw_score) if isinstance(raw_score, int | float) else 0.0
        return (-matches, priority, -score, description)

    @staticmethod
    def _parse_food(value: dict[str, object]) -> FoodNutrients | None:
        fdc_id = value.get("fdcId")
        description = value.get("description")
        data_type = value.get("dataType")
        nutrients = value.get("foodNutrients")
        if (
            not isinstance(fdc_id, int)
            or not isinstance(description, str)
            or data_type not in _DATA_TYPES
            or not isinstance(nutrients, list)
        ):
            return None

        amounts: dict[int, Decimal] = {}
        for row in nutrients:
            if not isinstance(row, dict):
                continue
            nutrient = row.get("nutrient")
            if not isinstance(nutrient, dict):
                continue
            nutrient_id = nutrient.get("id")
            expected_unit = "kcal" if nutrient_id in _ENERGY_IDS else "g"
            if nutrient_id not in {*_ENERGY_IDS, *_MACRO_IDS.values()}:
                continue
            if (
                str(nutrient.get("unitName", "")).casefold()
                != expected_unit.casefold()
            ):
                return None
            amount = _decimal(row.get("amount"))
            if amount is not None and amount >= 0:
                amounts[nutrient_id] = amount

        energy = next((amounts[key] for key in _ENERGY_IDS if key in amounts), None)
        if energy is None or any(key not in amounts for key in _MACRO_IDS.values()):
            return None

        portions: list[FoodPortion] = []
        raw_portions = value.get("foodPortions", [])
        if isinstance(raw_portions, list):
            for row in raw_portions:
                portion = USDAClient._parse_portion(row)
                if portion is not None:
                    portions.append(portion)

        return FoodNutrients(
            fdc_id=fdc_id,
            description=description,
            data_type=data_type,
            calories_per_100g=energy,
            protein_grams_per_100g=amounts[_MACRO_IDS["protein"]],
            carbohydrate_grams_per_100g=amounts[_MACRO_IDS["carbohydrate"]],
            fat_grams_per_100g=amounts[_MACRO_IDS["fat"]],
            portions=portions,
        )

    @staticmethod
    def _parse_portion(value: object) -> FoodPortion | None:
        if not isinstance(value, dict):
            return None
        amount = _decimal(value.get("amount"))
        grams = _decimal(value.get("gramWeight"))
        measure = value.get("measureUnit")
        if amount is None or grams is None or amount <= 0 or grams <= 0:
            return None
        if isinstance(measure, dict):
            unit = measure.get("abbreviation") or measure.get("name")
        else:
            unit = measure
        if not isinstance(unit, str) or not unit.strip():
            return None
        modifier = value.get("modifier")
        description = value.get("portionDescription")
        return FoodPortion(
            amount=amount,
            gram_weight=grams,
            measure_unit=unit.strip(),
            modifier=modifier if isinstance(modifier, str) else None,
            description=description if isinstance(description, str) else None,
        )


def _normalize(value: str) -> str:
    return " ".join(re.sub(r"[^a-z0-9]+", " ", value.casefold()).split())


def _decimal(value: object) -> Decimal | None:
    if not isinstance(value, int | float | str | Decimal) or isinstance(value, bool):
        return None
    try:
        parsed = Decimal(str(value))
    except InvalidOperation:
        return None
    return parsed if parsed.is_finite() else None
