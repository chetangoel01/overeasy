from collections.abc import Callable
from decimal import Decimal
from time import sleep
from typing import Any, Never
from uuid import UUID

import httpx
from pydantic import SecretStr

from ladle.acquisition.errors import (
    AcquisitionError,
    MalformedProviderResponse,
    PrivateOrDeleted,
    ProviderAuthenticationError,
    ProviderQuotaError,
    ProviderTransientError,
    ProviderUnavailable,
)
from ladle.acquisition.models import (
    SourceVideoDescriptor,
    TextEvidence,
    TranscriptResult,
)
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink


class SoScriptedClient:
    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: SecretStr,
        base_url: str,
        sleeper: Callable[[float], None] = sleep,
        request_attempts: int = 2,
        usage: ProviderUsageSink | None = None,
    ) -> None:
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._sleep = sleeper
        self._request_attempts = request_attempts
        self._usage = usage or NullProviderUsageSink()

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> TranscriptResult:
        idempotency_key = f"soscripted:transcript:{source.source_revision}"
        self._usage.started(
            job_id=job_id,
            provider="soscripted",
            operation="transcript",
            idempotency_key=idempotency_key,
            external_job_id=None,
            billed_units=Decimal(0),
        )
        try:
            response = self._request(source.canonical_url)
            payload = self._json_object(response)
            caption = payload.get("caption")
            if payload.get("ok") is not True or not isinstance(caption, dict):
                self._raise_payload_error(payload.get("error"))
            values = caption.get("segments")
            if not isinstance(values, list):
                raise MalformedProviderResponse("SoScripted segments are invalid")
            segments: list[TextEvidence] = []
            for value in values:
                if not isinstance(value, dict):
                    raise MalformedProviderResponse("SoScripted segment is invalid")
                try:
                    segments.append(
                        TextEvidence(
                            text=value["text"],
                            start_seconds=value["start"],
                            end_seconds=value["end"],
                            provenance="soscripted",
                            generated=True,
                        )
                    )
                except (KeyError, TypeError, ValueError) as error:
                    raise MalformedProviderResponse(
                        "SoScripted segment is invalid"
                    ) from error
            if not segments:
                raise ProviderUnavailable("SoScripted returned no transcript")
            result = TranscriptResult(
                segments=segments,
                billed_units=Decimal(1),
            )
        except AcquisitionError as error:
            self._usage.failed(
                job_id=job_id,
                idempotency_key=idempotency_key,
                failure_code=type(error).__name__,
            )
            raise
        self._usage.completed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            billed_units=result.billed_units,
            latency_ms=None,
        )
        return result

    def _request(self, url: str) -> httpx.Response:
        for attempt in range(self._request_attempts):
            try:
                response = self._http.post(
                    f"{self._base_url}/transcribe",
                    headers={
                        "authorization": (f"Bearer {self._api_key.get_secret_value()}"),
                        "content-type": "application/json",
                        "accept": "application/json",
                    },
                    json={"url": url},
                )
            except httpx.TransportError as error:
                if attempt + 1 == self._request_attempts:
                    raise ProviderTransientError(
                        "SoScripted transport unavailable"
                    ) from error
                self._sleep(2**attempt)
                continue
            if response.status_code >= 500:
                if attempt + 1 == self._request_attempts:
                    raise ProviderTransientError("SoScripted service unavailable")
                self._sleep(2**attempt)
                continue
            if response.status_code == 401:
                raise ProviderAuthenticationError("SoScripted authentication failed")
            if response.status_code == 402:
                raise ProviderQuotaError("SoScripted quota unavailable")
            if response.status_code == 400:
                self._raise_payload_error(self._json_object(response).get("error"))
            if response.status_code != 200:
                raise ProviderUnavailable(
                    f"SoScripted request failed ({response.status_code})"
                )
            return response
        raise AssertionError("unreachable")

    def _raise_payload_error(self, value: object) -> Never:
        text = str(value).casefold()
        if "private" in text or "not found" in text or "deleted" in text:
            raise PrivateOrDeleted
        raise ProviderUnavailable("SoScripted transcription failed")

    def _json_object(self, response: httpx.Response) -> dict[str, Any]:
        try:
            value = response.json()
        except ValueError as error:
            raise MalformedProviderResponse(
                "SoScripted returned malformed JSON"
            ) from error
        if not isinstance(value, dict):
            raise MalformedProviderResponse("SoScripted returned a non-object response")
        return value
