from collections.abc import Callable
from datetime import datetime
from decimal import Decimal, InvalidOperation
from time import sleep
from typing import Any, Literal, Never
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
    TranscriptUnavailable,
)
from ladle.acquisition.models import (
    MediaMetadata,
    SourceCounts,
    SourceVideoDescriptor,
    TextEvidence,
    TranscriptResult,
)
from ladle.usage.ledger import NullProviderUsageSink, ProviderUsageSink


class SupadataClient:
    def __init__(
        self,
        *,
        http: httpx.Client,
        api_key: SecretStr,
        base_url: str,
        poll_attempts: int = 60,
        sleeper: Callable[[float], None] = sleep,
        request_attempts: int = 2,
        usage: ProviderUsageSink | None = None,
    ) -> None:
        self._http = http
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._poll_attempts = poll_attempts
        self._sleep = sleeper
        self._request_attempts = request_attempts
        self._usage = usage or NullProviderUsageSink()

    @staticmethod
    def _whole(value: object) -> int | None:
        if isinstance(value, bool) or not isinstance(value, int):
            return None
        return value if value >= 0 else None

    def _counts(self, payload: dict[str, object]) -> SourceCounts:
        """Engagement counts from the same /metadata call the title comes from.

        This is the only count source that works for TikTok on server
        infrastructure: TikTok rejects yt-dlp from datacenter addresses, so the
        free path returns nothing there however current the binary is.
        """
        stats = payload.get("stats")
        stats = stats if isinstance(stats, dict) else {}
        published = self._optional_string(payload.get("createdAt"))
        published_at: datetime | None = None
        if published:
            try:
                published_at = datetime.fromisoformat(published.replace("Z", "+00:00"))
            except ValueError:
                published_at = None
        return SourceCounts(
            like_count=self._whole(stats.get("likes")),
            view_count=self._whole(stats.get("views")),
            comment_count=self._whole(stats.get("comments")),
            repost_count=self._whole(stats.get("shares")),
            published_at=published_at,
        )

    def metadata(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
    ) -> MediaMetadata:
        idempotency_key = f"supadata:metadata:{source.source_revision}"
        self._started(
            job_id,
            operation="metadata",
            idempotency_key=idempotency_key,
        )
        try:
            response = self._request(
                "GET",
                "/metadata",
                params={"url": source.canonical_url},
            )
            payload = self._json_object(response)
            author = payload.get("author")
            media = payload.get("media")
            result = MediaMetadata(
                title=self._optional_string(payload.get("title")),
                description=self._optional_string(payload.get("description")) or "",
                creator_name=(
                    self._optional_string(author.get("displayName"))
                    if isinstance(author, dict)
                    else None
                ),
                thumbnail_url=(
                    self._optional_string(media.get("thumbnailUrl"))
                    if isinstance(media, dict)
                    else None
                ),
                duration_seconds=(
                    self._optional_number(media.get("duration"))
                    if isinstance(media, dict)
                    else None
                ),
                counts=self._counts(payload),
                billed_units=self._billed_units(response),
            )
        except AcquisitionError as error:
            self._failed(job_id, idempotency_key, error)
            raise
        self._completed(
            job_id,
            idempotency_key=idempotency_key,
            billed_units=result.billed_units,
        )
        return result

    def transcript(
        self,
        source: SourceVideoDescriptor,
        *,
        job_id: UUID,
        mode: Literal["native", "auto", "generate"] | str,
    ) -> TranscriptResult:
        idempotency_key = f"supadata:transcript:{mode}:{source.source_revision}"
        existing_job_id = self._usage.existing_external_job_id(
            job_id=job_id,
            idempotency_key=idempotency_key,
        )
        self._started(
            job_id,
            operation=f"transcript:{mode}",
            idempotency_key=idempotency_key,
            external_job_id=existing_job_id,
        )
        external_job_id: str | None = existing_job_id
        try:
            if existing_job_id is not None:
                billed = Decimal(0)
                external_job_id = existing_job_id
                payload = self._poll("/transcript", external_job_id)
            else:
                response = self._request(
                    "GET",
                    "/transcript",
                    params={
                        "url": source.canonical_url,
                        "text": "false",
                        "mode": mode,
                    },
                    transcript_request=True,
                )
                billed = self._billed_units(response)
                payload = self._json_object(response)
                external_job_id = self._optional_string(payload.get("jobId"))
                if response.status_code == 202:
                    if external_job_id is None:
                        raise MalformedProviderResponse(
                            "Supadata omitted transcript job ID"
                        )
                    self._started(
                        job_id,
                        operation=f"transcript:{mode}",
                        idempotency_key=idempotency_key,
                        external_job_id=external_job_id,
                        billed_units=billed,
                    )
                    payload = self._poll("/transcript", external_job_id)
            result = self._parse_transcript(
                payload,
                mode=mode,
                billed_units=billed,
                external_job_id=external_job_id,
            )
        except AcquisitionError as error:
            self._failed(job_id, idempotency_key, error)
            raise
        self._completed(
            job_id,
            idempotency_key=idempotency_key,
            billed_units=result.billed_units,
        )
        return result

    def _parse_transcript(
        self,
        payload: dict[str, Any],
        *,
        mode: str,
        billed_units: Decimal,
        external_job_id: str | None,
    ) -> TranscriptResult:
        if payload.get("status") == "failed":
            self._raise_payload_error(payload.get("error"))
        content = payload.get("content")
        language = self._optional_string(payload.get("lang"))
        available = payload.get("availableLangs", [])
        if not isinstance(available, list) or not all(
            isinstance(value, str) for value in available
        ):
            raise MalformedProviderResponse("Supadata transcript languages are invalid")
        if isinstance(content, str):
            segments = (
                [
                    TextEvidence(
                        text=content,
                        provenance=f"supadata-{mode}",
                        generated=mode != "native",
                    )
                ]
                if content.strip()
                else []
            )
        elif isinstance(content, list):
            segments = []
            for value in content:
                if not isinstance(value, dict):
                    raise MalformedProviderResponse(
                        "Supadata transcript segment is invalid"
                    )
                try:
                    start = float(value["offset"]) / 1000
                    duration = float(value["duration"]) / 1000
                    segments.append(
                        TextEvidence(
                            text=value["text"],
                            start_seconds=start,
                            end_seconds=start + duration,
                            provenance=f"supadata-{mode}",
                            generated=mode != "native",
                        )
                    )
                except (KeyError, TypeError, ValueError) as error:
                    raise MalformedProviderResponse(
                        "Supadata transcript segment is invalid"
                    ) from error
        else:
            raise MalformedProviderResponse("Supadata transcript content is invalid")
        if not segments:
            raise TranscriptUnavailable
        return TranscriptResult(
            segments=segments,
            language=language,
            available_languages=available,
            billed_units=billed_units,
            external_job_id=external_job_id,
        )

    def _poll(self, operation: str, job_id: str) -> dict[str, Any]:
        for attempt in range(self._poll_attempts):
            response = self._request("GET", f"{operation}/{job_id}")
            payload = self._json_object(response)
            status = payload.get("status")
            if status == "completed":
                return payload
            if status == "failed":
                self._raise_payload_error(payload.get("error"))
            if status not in {"queued", "active"}:
                raise MalformedProviderResponse("Supadata job status is invalid")
            if attempt + 1 < self._poll_attempts:
                self._sleep(1)
        raise ProviderTransientError("Supadata job did not finish before poll limit")

    def _request(
        self,
        method: str,
        path: str,
        *,
        transcript_request: bool = False,
        **kwargs: Any,
    ) -> httpx.Response:
        for attempt in range(self._request_attempts):
            try:
                response = self._http.request(
                    method,
                    f"{self._base_url}{path}",
                    headers={
                        "x-api-key": self._api_key.get_secret_value(),
                        "accept": "application/json",
                    },
                    **kwargs,
                )
            except httpx.TransportError as error:
                if attempt + 1 == self._request_attempts:
                    raise ProviderTransientError(
                        "Supadata transport unavailable"
                    ) from error
                self._sleep(2**attempt)
                continue
            if response.status_code >= 500:
                if attempt + 1 == self._request_attempts:
                    raise ProviderTransientError("Supadata service unavailable")
                self._sleep(2**attempt)
                continue
            self._raise_http_error(
                response,
                transcript_request=transcript_request,
            )
            return response
        raise AssertionError("unreachable")

    def _raise_http_error(
        self,
        response: httpx.Response,
        *,
        transcript_request: bool,
    ) -> None:
        if response.status_code in {200, 201, 202}:
            return
        if transcript_request and response.status_code == 206:
            raise TranscriptUnavailable
        if response.status_code in {403, 404}:
            raise PrivateOrDeleted
        if response.status_code == 401:
            raise ProviderAuthenticationError("Supadata authentication failed")
        if response.status_code in {402, 429}:
            raise ProviderQuotaError("Supadata quota unavailable")
        raise ProviderUnavailable(f"Supadata request failed ({response.status_code})")

    def _raise_payload_error(self, value: object) -> Never:
        text = str(value).casefold()
        if "private" in text or "not found" in text or "restricted" in text:
            raise PrivateOrDeleted
        if "quota" in text or "limit" in text or "credit" in text:
            raise ProviderQuotaError("Supadata quota unavailable")
        raise ProviderUnavailable("Supadata job failed")

    def _json_object(self, response: httpx.Response) -> dict[str, Any]:
        try:
            value = response.json()
        except ValueError as error:
            raise MalformedProviderResponse(
                "Supadata returned malformed JSON"
            ) from error
        if not isinstance(value, dict):
            raise MalformedProviderResponse("Supadata returned a non-object response")
        return value

    def _billed_units(self, response: httpx.Response) -> Decimal:
        raw = response.headers.get("x-billable-requests", "0")
        try:
            return Decimal(raw)
        except InvalidOperation as error:
            raise MalformedProviderResponse(
                "Supadata billable request header is invalid"
            ) from error

    def _optional_string(self, value: object) -> str | None:
        return value if isinstance(value, str) else None

    def _optional_number(self, value: object) -> float | None:
        if isinstance(value, int | float):
            return float(value)
        return None

    def _started(
        self,
        job_id: UUID,
        *,
        operation: str,
        idempotency_key: str,
        external_job_id: str | None = None,
        billed_units: Decimal = Decimal(0),
    ) -> None:
        self._usage.started(
            job_id=job_id,
            provider="supadata",
            operation=operation,
            idempotency_key=idempotency_key,
            external_job_id=external_job_id,
            billed_units=billed_units,
        )

    def _completed(
        self,
        job_id: UUID,
        *,
        idempotency_key: str,
        billed_units: Decimal,
    ) -> None:
        self._usage.completed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            billed_units=billed_units,
            latency_ms=None,
        )

    def _failed(
        self,
        job_id: UUID,
        idempotency_key: str,
        error: AcquisitionError,
    ) -> None:
        self._usage.failed(
            job_id=job_id,
            idempotency_key=idempotency_key,
            failure_code=type(error).__name__,
        )
