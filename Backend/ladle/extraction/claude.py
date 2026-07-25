from dataclasses import dataclass
from decimal import Decimal
from typing import Protocol
from uuid import UUID

import anthropic

from ladle.acquisition.models import AcquiredVideoContext
from ladle.extraction.models import RecipeExtraction
from ladle.extraction.prompt import PROMPT_VERSION, SYSTEM_PROMPT, build_user_prompt
from ladle.extraction.review import build_reviewed_template
from ladle.recipes.template_clone import RecipeTemplate
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink


class ExtractionUnavailable(Exception):
    pass


class ExtractionRefused(ExtractionUnavailable):
    pass


class ExtractionTruncated(ExtractionUnavailable):
    pass


class MalformedExtraction(ExtractionUnavailable):
    pass


@dataclass(frozen=True)
class ClaudeStructuredResponse:
    stop_reason: str
    parsed_output: RecipeExtraction | None
    input_tokens: int
    output_tokens: int


class ClaudeStructuredClient(Protocol):
    def parse_recipe(
        self,
        *,
        model: str,
        max_tokens: int,
        system: str,
        user_prompt: str,
    ) -> ClaudeStructuredResponse: ...


class AnthropicStructuredClient:
    def __init__(self, client: anthropic.Anthropic) -> None:
        self._client = client

    def parse_recipe(
        self,
        *,
        model: str,
        max_tokens: int,
        system: str,
        user_prompt: str,
    ) -> ClaudeStructuredResponse:
        message = self._client.messages.parse(
            model=model,
            max_tokens=max_tokens,
            temperature=0,
            system=system,
            messages=[{"role": "user", "content": user_prompt}],
            output_format=RecipeExtraction,
        )
        return ClaudeStructuredResponse(
            stop_reason=message.stop_reason or "unknown",
            parsed_output=message.parsed_output,
            input_tokens=message.usage.input_tokens,
            output_tokens=message.usage.output_tokens,
        )


class ClaudeRecipeExtractor:
    contract_version = "v1"
    prompt_version = PROMPT_VERSION

    def __init__(
        self,
        *,
        client: ClaudeStructuredClient,
        model_id: str,
        max_tokens: int,
        usage: ProviderUsageSink | None = None,
        provider: str = "anthropic",
    ) -> None:
        self._client = client
        self._model_id = model_id
        self._max_tokens = max_tokens
        self._usage = usage or NullProviderUsageSink()
        self._provider = provider

    @property
    def model_id(self) -> str:
        return self._model_id

    def extract(
        self,
        context: AcquiredVideoContext,
        *,
        job_id: UUID,
    ) -> RecipeTemplate:
        idempotency_key = (
            f"{self._provider}:extract:{self.prompt_version}:{self._model_id}"
        )
        self._usage.started(
            job_id=job_id,
            provider=self._provider,
            operation="recipeExtraction",
            idempotency_key=idempotency_key,
            external_job_id=None,
            billed_units=Decimal(0),
        )
        try:
            response = self._client.parse_recipe(
                model=self._model_id,
                max_tokens=self._max_tokens,
                system=SYSTEM_PROMPT,
                user_prompt=build_user_prompt(context),
            )
        except (
            anthropic.APITimeoutError,
            anthropic.APIConnectionError,
            anthropic.RateLimitError,
            TimeoutError,
            ExtractionUnavailable,
        ) as error:
            self._usage.failed(
                job_id=job_id,
                idempotency_key=idempotency_key,
                failure_code=type(error).__name__,
            )
            if isinstance(error, ExtractionUnavailable):
                raise
            raise ExtractionUnavailable("Claude extraction unavailable") from error

        billed_tokens = Decimal(response.input_tokens + response.output_tokens)
        self._usage.started(
            job_id=job_id,
            provider=self._provider,
            operation="recipeExtraction",
            idempotency_key=idempotency_key,
            external_job_id=None,
            billed_units=billed_tokens,
        )
        if response.stop_reason == "refusal":
            self._fail(job_id, idempotency_key, ExtractionRefused)
            raise ExtractionRefused
        if response.stop_reason == "max_tokens":
            self._fail(job_id, idempotency_key, ExtractionTruncated)
            raise ExtractionTruncated
        if response.parsed_output is None:
            self._fail(job_id, idempotency_key, MalformedExtraction)
            raise MalformedExtraction
        template = build_reviewed_template(response.parsed_output, context=context)
        self._usage.completed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            billed_units=billed_tokens,
            latency_ms=None,
        )
        return template

    def _fail(
        self,
        job_id: UUID,
        idempotency_key: str,
        error_type: type[Exception],
    ) -> None:
        self._usage.failed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            failure_code=error_type.__name__,
        )
