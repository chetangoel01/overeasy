import json
import logging
import time
from collections.abc import Callable
from dataclasses import replace
from decimal import Decimal, InvalidOperation

import httpx
from pydantic import ValidationError

from ladle.extraction.claude import (
    ClaudeStructuredResponse,
    ExtractionUnavailable,
)
from ladle.extraction.models import RecipeExtraction

LOGGER = logging.getLogger(__name__)

_FINISH_REASON_TO_STOP_REASON = {
    "length": "max_tokens",
    "content_filter": "refusal",
}


def _unfenced(content: str) -> str:
    """Strip a markdown code fence the model was asked not to emit.

    It emits one anyway often enough to matter: the retry hid the cost by
    spending a second billed call on what is a formatting habit, and a model
    in the habit fences the retry too.
    """

    text = content.strip()
    if not text.startswith("```"):
        return text
    body = text[3:]
    # Drop the language tag on the opening fence ("json").
    newline = body.find("\n")
    if newline != -1 and "{" not in body[:newline] and "[" not in body[:newline]:
        body = body[newline + 1 :]
    closing = body.rfind("```")
    if closing != -1:
        body = body[:closing]
    return body.strip()


class OpenRouterStructuredClient:
    """Chat-completions client for OpenRouter's OpenAI-compatible API.

    Satisfies the same protocol as the native Anthropic client: transport
    and provider failures surface as ExtractionUnavailable (the recoverable
    import path), schema drift surfaces as a None parsed_output.
    """

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

    def parse_recipe(
        self,
        *,
        model: str,
        max_tokens: int,
        system: str,
        user_prompt: str,
    ) -> ClaudeStructuredResponse:
        # OpenRouter load-balances across upstreams whose schema enforcement
        # varies, so an unparseable body is often transient. Retry once
        # before surfacing a failure the cook has to recover from by hand.
        response = self._attempt(
            model=model,
            max_tokens=max_tokens,
            system=system,
            user_prompt=user_prompt,
        )
        if response.parsed_output is not None or response.stop_reason != "end_turn":
            return response
        retry = self._attempt(
            model=model,
            max_tokens=max_tokens,
            system=system,
            user_prompt=user_prompt,
        )
        return replace(
            retry,
            input_tokens=response.input_tokens + retry.input_tokens,
            output_tokens=response.output_tokens + retry.output_tokens,
            cost_usd=_sum_cost(response.cost_usd, retry.cost_usd),
        )

    def _attempt(
        self,
        *,
        model: str,
        max_tokens: int,
        system: str,
        user_prompt: str,
    ) -> ClaudeStructuredResponse:
        schema = RecipeExtraction.model_json_schema()
        payload = {
            "model": model,
            "max_tokens": max_tokens,
            "temperature": 0,
            # Route only to upstreams that actually enforce response_format;
            # the rest silently return their own ad-hoc JSON shape.
            "provider": {"require_parameters": True},
            "messages": [
                {
                    "role": "system",
                    "content": (
                        f"{system}\n\nRespond with a single JSON object that "
                        "validates against this JSON Schema. Emit no prose "
                        f"and no code fences.\n{json.dumps(schema)}"
                    ),
                },
                {"role": "user", "content": user_prompt},
            ],
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "recipe_extraction",
                    "strict": True,
                    "schema": schema,
                },
            },
        }
        for attempt in range(4):
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
                raise ExtractionUnavailable(
                    "OpenRouter extraction unavailable"
                ) from error
            if response.status_code != 429 or attempt == 3:
                break
            self._sleep(
                _retry_after_seconds(response, default=2 ** (attempt + 1))
            )
        if response.status_code >= 400:
            raise ExtractionUnavailable(
                f"OpenRouter extraction failed with HTTP {response.status_code}"
            )

        try:
            data = response.json()
            choice = data["choices"][0]
        except (json.JSONDecodeError, LookupError, TypeError) as error:
            raise ExtractionUnavailable(
                "OpenRouter returned an unreadable completion"
            ) from error

        finish_reason = choice.get("finish_reason") or "unknown"
        stop_reason = _FINISH_REASON_TO_STOP_REASON.get(finish_reason, "end_turn")

        parsed: RecipeExtraction | None = None
        content = (choice.get("message") or {}).get("content")
        if isinstance(content, str) and content.strip():
            try:
                parsed = RecipeExtraction.model_validate_json(_unfenced(content))
            except ValidationError as error:
                # Swallowing this silently cost real debugging: a whole
                # extraction would vanish with nothing recorded about why, and
                # the cause turned out to be a single fraction in one field.
                LOGGER.warning(
                    "Extraction did not match the schema (%d errors): %s",
                    error.error_count(),
                    "; ".join(
                        f"{'.'.join(str(part) for part in item['loc'])}="
                        f"{item.get('input')!r}"
                        for item in error.errors()[:5]
                    ),
                )
                parsed = None

        usage = data.get("usage") or {}
        return ClaudeStructuredResponse(
            stop_reason=stop_reason,
            parsed_output=parsed,
            input_tokens=int(usage.get("prompt_tokens") or 0),
            output_tokens=int(usage.get("completion_tokens") or 0),
            cost_usd=_cost_usd(usage.get("cost")),
        )


def _cost_usd(value: object) -> Decimal | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        parsed = Decimal(str(value))
    except InvalidOperation:
        return None
    return parsed if parsed.is_finite() and parsed >= 0 else None


def _retry_after_seconds(response: httpx.Response, *, default: int) -> float:
    try:
        delay = Decimal(response.headers.get("Retry-After", str(default)))
    except InvalidOperation:
        return float(default)
    if not delay.is_finite() or delay < 0:
        return float(default)
    return float(min(delay, Decimal(60)))


def _sum_cost(first: Decimal | None, second: Decimal | None) -> Decimal | None:
    if first is None and second is None:
        return None
    return (first or Decimal(0)) + (second or Decimal(0))
