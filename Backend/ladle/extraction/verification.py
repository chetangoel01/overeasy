"""Targeted, evidence-bound verification for disputed recipe fields."""

import json
import re
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Protocol
from uuid import UUID

import anthropic
import httpx
from pydantic import Field, ValidationError

from ladle.acquisition.models import AcquiredVideoContext
from ladle.contracts.common import WireModel
from ladle.contracts.recipes import FieldUncertaintyDTO, RecipeReviewStatus
from ladle.recipes.template_clone import RecipeTemplate
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink

_NUMBER = r"(?:\d+(?:\.\d+)?|\d+\s*/\s*\d+)"
_PORTION_UNIT = (
    r"(?:cups?|tablespoons?|tbsp|teaspoons?|tsp|grams?|g|kilograms?|kg|"
    r"ounces?|oz|pounds?|lbs?|pieces?|slices?)"
)
_FIELD_PATH = re.compile(
    r"^(?:servings|servings_basis|preparation_minutes|cooking_minutes|"
    r"total_minutes|ingredients\[(\d+)]\."
    r"(?:quantity_text|normalized_quantity|unit|metric_amount|metric_unit))$"
)
_WORD_NUMBERS = {
    "one": Decimal(1),
    "two": Decimal(2),
    "three": Decimal(3),
    "four": Decimal(4),
    "five": Decimal(5),
    "six": Decimal(6),
    "seven": Decimal(7),
    "eight": Decimal(8),
    "nine": Decimal(9),
    "ten": Decimal(10),
    "twelve": Decimal(12),
}


class VerificationEvidence(WireModel):
    text: str = Field(min_length=1, max_length=20_000)
    provenance: str = Field(min_length=1)


class VerificationIssue(WireModel):
    field_path: str = Field(min_length=1)
    reason: str = Field(min_length=1)
    supporting_evidence: list[str] = Field(default_factory=list)


class VerificationPatch(WireModel):
    field_path: str = Field(min_length=1)
    value: int | str | list[int] | None
    supporting_evidence: str = Field(min_length=1, max_length=2_000)


class VerificationResponse(WireModel):
    patches: list[VerificationPatch] = Field(default_factory=list)


@dataclass(frozen=True)
class StructuredVerificationResponse:
    parsed_output: VerificationResponse | None
    input_tokens: int
    output_tokens: int


class VerificationModelClient(Protocol):
    def propose_patches(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        issues: list[VerificationIssue],
        evidence: list[VerificationEvidence],
    ) -> StructuredVerificationResponse: ...


class VerificationUnavailable(Exception):
    pass


def verification_evidence(
    context: AcquiredVideoContext,
) -> list[VerificationEvidence]:
    """Copy only textual acquisition evidence into the verifier boundary."""

    values: list[VerificationEvidence] = []
    if context.title:
        values.append(
            VerificationEvidence(text=context.title, provenance="metadata-title")
        )
    if context.description.strip():
        values.append(
            VerificationEvidence(
                text=context.description,
                provenance="metadata-description",
            )
        )
    values.extend(
        VerificationEvidence(text=value.text, provenance=value.provenance)
        for value in context.transcript
    )
    values.extend(
        VerificationEvidence(text=value.text, provenance=value.provenance)
        for value in context.linked_documents
    )
    return values


class OpenRouterVerificationClient:
    """Strict text-only structured-output client for verification patches."""

    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: str,
        base_url: str,
    ) -> None:
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")

    def propose_patches(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        issues: list[VerificationIssue],
        evidence: list[VerificationEvidence],
    ) -> StructuredVerificationResponse:
        schema = VerificationResponse.model_json_schema()
        source = {
            "template": template.model_dump(mode="json", by_alias=True),
            "issues": [
                value.model_dump(mode="json", by_alias=True) for value in issues
            ],
            "evidence": [
                value.model_dump(mode="json", by_alias=True) for value in evidence
            ],
        }
        payload = {
            "model": model,
            "max_tokens": max_tokens,
            "temperature": 0,
            "provider": {"require_parameters": True},
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "You verify only disputed recipe fields against text. "
                        "Return the smallest patches needed. Patch only a listed "
                        "fieldPath, copy supportingEvidence exactly from the given "
                        "text evidence, and omit any patch that is not explicit. "
                        "Never infer from images, video, general recipe knowledge, "
                        "or nutrition arithmetic."
                    ),
                },
                {
                    "role": "user",
                    "content": json.dumps(source, separators=(",", ":")),
                },
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "recipe_verification",
                    "strict": True,
                    "schema": schema,
                },
            },
        }
        try:
            response = self._http.post(
                f"{self._base_url}/chat/completions",
                headers={
                    "Authorization": f"Bearer {self._api_key}",
                    "X-Title": "Overeasy",
                },
                json=payload,
            )
        except httpx.HTTPError as error:
            raise VerificationUnavailable(
                "verification transport unavailable"
            ) from error
        if response.status_code >= 400:
            raise VerificationUnavailable(
                f"verification failed with HTTP {response.status_code}"
            )
        try:
            data = response.json()
            choice = data["choices"][0]
            content = choice["message"]["content"]
            if choice.get("finish_reason") == "length":
                raise VerificationUnavailable("verification response was truncated")
            parsed = VerificationResponse.model_validate_json(_unfenced(content))
            usage = data.get("usage") or {}
            return StructuredVerificationResponse(
                parsed_output=parsed,
                input_tokens=int(usage.get("prompt_tokens") or 0),
                output_tokens=int(usage.get("completion_tokens") or 0),
            )
        except (json.JSONDecodeError, LookupError, TypeError, ValidationError) as error:
            raise VerificationUnavailable(
                "verification returned unreadable structured output"
            ) from error


class AnthropicVerificationClient:
    def __init__(self, client: anthropic.Anthropic) -> None:
        self._client = client

    def propose_patches(
        self,
        *,
        model: str,
        max_tokens: int,
        template: RecipeTemplate,
        issues: list[VerificationIssue],
        evidence: list[VerificationEvidence],
    ) -> StructuredVerificationResponse:
        source = {
            "template": template.model_dump(mode="json", by_alias=True),
            "issues": [
                value.model_dump(mode="json", by_alias=True) for value in issues
            ],
            "evidence": [
                value.model_dump(mode="json", by_alias=True) for value in evidence
            ],
        }
        try:
            message = self._client.messages.parse(
                model=model,
                max_tokens=max_tokens,
                temperature=0,
                system=(
                    "Verify only disputed recipe fields against the supplied text. "
                    "Patch only a listed fieldPath and cite exact supplied text. "
                    "Omit anything not explicit; never use visual or general recipe "
                    "knowledge."
                ),
                messages=[
                    {
                        "role": "user",
                        "content": json.dumps(source, separators=(",", ":")),
                    }
                ],
                output_format=VerificationResponse,
            )
        except (
            anthropic.APITimeoutError,
            anthropic.APIConnectionError,
            anthropic.RateLimitError,
            TimeoutError,
        ) as error:
            raise VerificationUnavailable(
                "verification provider unavailable"
            ) from error
        if message.stop_reason in {"refusal", "max_tokens"}:
            raise VerificationUnavailable("verification did not complete")
        return StructuredVerificationResponse(
            parsed_output=message.parsed_output,
            input_tokens=message.usage.input_tokens,
            output_tokens=message.usage.output_tokens,
        )


def deterministic_issues(
    template: RecipeTemplate,
    evidence: list[VerificationEvidence],
) -> list[VerificationIssue]:
    issues: list[VerificationIssue] = []
    ingredient_count = len(template.ingredients)
    referenced: set[int] = set()
    for step_index, step in enumerate(template.steps):
        invalid = [
            value
            for value in step.ingredient_indexes
            if value < 0 or value >= ingredient_count
        ]
        if invalid:
            issues.append(
                VerificationIssue(
                    field_path=f"steps[{step_index}].ingredient_indexes",
                    reason="The step references an ingredient outside the recipe.",
                    supporting_evidence=[step.instruction],
                )
            )
        referenced.update(
            value for value in step.ingredient_indexes if 0 <= value < ingredient_count
        )

    stated_servings = _stated_servings(evidence)
    if stated_servings and (
        template.servings_basis != "stated"
        or len(stated_servings) > 1
        or next(iter(stated_servings)) != template.servings
    ):
        issues.append(
            VerificationIssue(
                field_path="servings",
                reason=(
                    "The serving value or its provenance conflicts with explicit "
                    "yield text."
                ),
                supporting_evidence=_matching_text(evidence, _SERVING_PATTERN),
            )
        )
    elif not stated_servings and template.servings_basis == "stated":
        issues.append(
            VerificationIssue(
                field_path="servings_basis",
                reason="The stated serving basis has no explicit yield text.",
                supporting_evidence=[],
            )
        )

    if (
        template.preparation_minutes is not None
        and template.cooking_minutes is not None
        and template.total_minutes is not None
        and template.total_minutes
        < template.preparation_minutes + template.cooking_minutes
    ):
        issues.append(
            VerificationIssue(
                field_path="total_minutes",
                reason="Total time is shorter than preparation plus cooking time.",
                supporting_evidence=_time_text(evidence),
            )
        )

    nutrition = template.nutrition
    if (
        nutrition is not None
        and nutrition.calories is not None
        and nutrition.protein_grams is not None
        and nutrition.carbohydrate_grams is not None
        and nutrition.fat_grams is not None
    ):
        macro_calories = (
            nutrition.protein_grams * 4
            + nutrition.carbohydrate_grams * 4
            + nutrition.fat_grams * 9
        )
        denominator = max(nutrition.calories, macro_calories, Decimal(1))
        if abs(nutrition.calories - macro_calories) / denominator > Decimal("0.25"):
            issues.append(
                VerificationIssue(
                    field_path="nutrition",
                    reason="Calories are grossly inconsistent with the stated macros.",
                    supporting_evidence=(
                        [nutrition.evidence] if nutrition.evidence else []
                    ),
                )
            )

    for index, ingredient in enumerate(template.ingredients):
        if ingredient.is_to_taste:
            continue
        ingredient_text = _ingredient_text(evidence, ingredient.name)
        if index not in referenced:
            issues.append(
                VerificationIssue(
                    field_path=f"ingredients[{index}]",
                    reason=(
                        f"{ingredient.name} is not connected to any method step."
                    ),
                    supporting_evidence=ingredient_text,
                )
            )
        amounts = _source_amounts(ingredient.name, evidence)
        if len(amounts) > 1:
            issues.append(
                VerificationIssue(
                    field_path=f"ingredients[{index}].normalized_quantity",
                    reason=(
                        f"The source gives conflicting amounts for {ingredient.name}."
                    ),
                    supporting_evidence=ingredient_text,
                )
            )
    return issues


class TargetedRecipeVerifier:
    """Run one structured repair pass and retain every unresolved issue."""

    def __init__(
        self,
        *,
        client: VerificationModelClient,
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

    def verify(
        self,
        template: RecipeTemplate,
        *,
        evidence: list[VerificationEvidence],
        job_id: UUID,
    ) -> RecipeTemplate:
        issues = deterministic_issues(template, evidence)
        if not issues:
            return template
        relevant = _relevant_evidence(issues, evidence)
        key = f"{self._provider}:verify:v1:{self._model_id}"
        self._usage.started(
            job_id=job_id,
            provider=self._provider,
            operation="recipeVerification",
            idempotency_key=key,
            external_job_id=None,
            billed_units=Decimal(0),
        )
        try:
            response = self._client.propose_patches(
                model=self._model_id,
                max_tokens=self._max_tokens,
                template=template,
                issues=issues,
                evidence=relevant,
            )
            if response.parsed_output is None:
                raise VerificationUnavailable("verifier returned no structured output")
        except VerificationUnavailable as error:
            self._usage.failed(
                job_id=job_id,
                idempotency_key=key,
                failure_code=type(error).__name__,
            )
            return _with_issues(template, issues)

        billed_units = Decimal(1)
        self._usage.started(
            job_id=job_id,
            provider=self._provider,
            operation="recipeVerification",
            idempotency_key=key,
            external_job_id=None,
            billed_units=billed_units,
        )
        updated = template
        flagged = {issue.field_path for issue in issues}
        for patch in response.parsed_output.patches:
            if patch.field_path not in flagged:
                continue
            candidate = _apply_patch(updated, patch, relevant)
            if candidate is not None:
                updated = candidate
        remaining = deterministic_issues(updated, evidence)
        self._usage.completed(
            job_id=job_id,
            idempotency_key=key,
            billed_units=billed_units,
            latency_ms=None,
        )
        return _with_issues(updated, remaining) if remaining else updated


_SERVING_PATTERN = re.compile(
    r"\b(?:(?:serves?|makes|yields?)\s+(?:about\s+)?"
    r"(\d+(?:\.\d+)?|one|two|three|four|five|six|seven|eight|nine|ten|twelve)"
    r"|(\d+(?:\.\d+)?)\s+servings?)\b",
    re.IGNORECASE,
)


def _stated_servings(evidence: list[VerificationEvidence]) -> set[Decimal]:
    values: set[Decimal] = set()
    for span in evidence:
        for match in _SERVING_PATTERN.finditer(span.text):
            raw = (match.group(1) or match.group(2)).casefold()
            parsed = _WORD_NUMBERS.get(raw) or _decimal(raw)
            if parsed is not None and parsed > 0:
                values.add(parsed)
    return values


def _matching_text(
    evidence: list[VerificationEvidence],
    pattern: re.Pattern[str],
) -> list[str]:
    return [span.text for span in evidence if pattern.search(span.text)]


def _time_text(evidence: list[VerificationEvidence]) -> list[str]:
    return [
        span.text
        for span in evidence
        if re.search(r"\b(?:minute|minutes|min|hour|hours|hr)\b", span.text, re.I)
    ]


def _ingredient_text(
    evidence: list[VerificationEvidence],
    name: str,
) -> list[str]:
    pattern = re.compile(rf"\b{re.escape(name)}\b", re.IGNORECASE)
    return _matching_text(evidence, pattern)


def _source_amounts(
    name: str,
    evidence: list[VerificationEvidence],
) -> set[tuple[Decimal, str]]:
    pattern = re.compile(
        rf"\b({_NUMBER})\s*({_PORTION_UNIT})\s+(?:of\s+)?{re.escape(name)}\b",
        re.IGNORECASE,
    )
    amounts: set[tuple[Decimal, str]] = set()
    for span in evidence:
        for match in pattern.finditer(span.text):
            amount = _fraction(match.group(1))
            if amount is not None:
                amounts.add((amount, _singular_unit(match.group(2))))
    return amounts


def _relevant_evidence(
    issues: list[VerificationIssue],
    evidence: list[VerificationEvidence],
) -> list[VerificationEvidence]:
    citations = [
        citation.casefold()
        for issue in issues
        for citation in issue.supporting_evidence
    ]
    return [
        span
        for span in evidence
        if any(citation in span.text.casefold() for citation in citations)
    ]


def _apply_patch(
    template: RecipeTemplate,
    patch: VerificationPatch,
    evidence: list[VerificationEvidence],
) -> RecipeTemplate | None:
    cited = patch.supporting_evidence.strip()
    if not any(cited.casefold() in span.text.casefold() for span in evidence):
        return None
    match = _FIELD_PATH.fullmatch(patch.field_path)
    if match is None:
        return None
    payload = template.model_dump(mode="json")
    value = patch.value
    try:
        if patch.field_path in {
            "preparation_minutes",
            "cooking_minutes",
            "total_minutes",
        }:
            if not isinstance(value, int | str) or isinstance(value, bool):
                return None
            parsed_int = int(value)
            if parsed_int < 0:
                return None
            parsed: object = parsed_int
        elif patch.field_path == "servings":
            parsed_decimal = _decimal(value)
            if parsed_decimal is None or parsed_decimal <= 0:
                return None
            parsed = format(parsed_decimal, "f")
            payload["servings_basis"] = "stated"
        elif patch.field_path == "servings_basis":
            if value not in {"stated", "unknown"}:
                return None
            parsed = value
        else:
            ingredient_index = int(match.group(1))
            if ingredient_index >= len(template.ingredients):
                return None
            field = patch.field_path.rsplit(".", 1)[-1]
            if field in {"normalized_quantity", "metric_amount"}:
                parsed_decimal = _decimal(value)
                if parsed_decimal is None or parsed_decimal < 0:
                    return None
                parsed = format(parsed_decimal, "f")
            elif field == "metric_unit":
                if value not in {"g", "ml", None}:
                    return None
                parsed = value
            elif isinstance(value, str | None):
                parsed = value
            else:
                return None
            payload["ingredients"][ingredient_index][field] = parsed
            if not _value_is_cited(parsed, cited):
                return None
            return RecipeTemplate.model_validate(payload)
    except (InvalidOperation, TypeError, ValueError):
        return None
    if not _value_is_cited(parsed, cited):
        return None
    payload[patch.field_path] = parsed
    try:
        return RecipeTemplate.model_validate(payload)
    except ValueError:
        return None


def _value_is_cited(value: object, evidence: str) -> bool:
    if value is None:
        return False
    return str(value).casefold() in evidence.casefold()


def _with_issues(
    template: RecipeTemplate,
    issues: list[VerificationIssue],
) -> RecipeTemplate:
    if not issues:
        return template
    uncertainties = list(template.uncertainties)
    existing = {value.field for value in uncertainties}
    uncertainties.extend(
        FieldUncertaintyDTO(field=issue.field_path, reason=issue.reason)
        for issue in issues
        if issue.field_path not in existing
    )
    return template.model_copy(
        update={
            "review_status": RecipeReviewStatus.NEEDS_REVIEW,
            "uncertainties": uncertainties,
        }
    )


def _decimal(value: object) -> Decimal | None:
    if isinstance(value, bool | list) or value is None:
        return None
    try:
        result = Decimal(str(value).strip())
    except (InvalidOperation, ValueError):
        return None
    return result if result.is_finite() else None


def _fraction(value: str) -> Decimal | None:
    compact = value.replace(" ", "")
    if "/" not in compact:
        return _decimal(compact)
    numerator, denominator = compact.split("/", 1)
    bottom = _decimal(denominator)
    if bottom is None or bottom == 0:
        return None
    top = _decimal(numerator)
    return top / bottom if top is not None else None


def _singular_unit(value: str) -> str:
    normalized = value.casefold()
    return normalized[:-1] if normalized.endswith("s") else normalized


def _unfenced(value: object) -> str:
    if not isinstance(value, str):
        raise TypeError("verification content is not text")
    text = value.strip()
    if not text.startswith("```"):
        return text
    body = text[3:]
    newline = body.find("\n")
    if newline >= 0 and "{" not in body[:newline]:
        body = body[newline + 1 :]
    closing = body.rfind("```")
    return (body[:closing] if closing >= 0 else body).strip()
