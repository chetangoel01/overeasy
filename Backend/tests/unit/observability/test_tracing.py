import asyncio
import json
from collections.abc import Iterator
from contextlib import contextmanager

import anthropic
import httpcore
import httpcore2
import httpx
import httpx2
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.instrumentation._semconv import (
    _OpenTelemetrySemanticConventionStability,
)
from opentelemetry.instrumentation.celery import CeleryInstrumentor
from opentelemetry.instrumentation.httpx import (
    HTTPX2ClientInstrumentor,
    HTTPXClientInstrumentor,
)
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.trace import SpanKind

from ladle.config import Settings
from ladle.extraction.claude import AnthropicStructuredClient
from ladle.extraction.models import (
    ExtractedIngredient,
    ExtractedStep,
    RecipeExtraction,
)
from ladle.observability.tracing import instrument_application, instrument_worker


def _tracing_settings() -> Settings:
    return Settings(
        tracing_enabled=True,
        tracing_otlp_endpoint="https://telemetry.example.test/v1/traces",
        _env_file=None,
    )


@contextmanager
def _dependencies_uninstrumented(provider: TracerProvider) -> Iterator[None]:
    """Undo the process-wide patches an entry point installs.

    Each instrumentor is a singleton that refuses a second `instrument()`, so
    one left behind would route a later test's spans to this shut-down
    provider and fail it by ordering alone."""
    try:
        yield
    finally:
        HTTPXClientInstrumentor().uninstrument()
        HTTPX2ClientInstrumentor().uninstrument()
        RedisInstrumentor().uninstrument()
        CeleryInstrumentor().uninstrument()
        provider.shutdown()


def test_fastapi_requests_emit_otlp_compatible_spans() -> None:
    app = FastAPI()

    @app.get("/trace-test")
    def traced() -> dict[str, str]:
        return {"status": "ok"}

    exporter = InMemorySpanExporter()
    provider = instrument_application(
        app,
        settings=_tracing_settings(),
        exporter=exporter,
    )

    with TestClient(app) as client:
        assert client.get("/trace-test").status_code == 200
    provider.force_flush()
    spans = exporter.get_finished_spans()

    assert any(span.name == "GET /trace-test" for span in spans)
    assert all(span.resource.attributes["service.name"] == "ladle" for span in spans)
    provider.shutdown()


SECRET = "sk-live-usda-key"
BASE = "https://api.nal.usda.gov/fdc/v1/foods/search"


class _StubPool:
    """Answer every request with an empty 200 without opening a socket."""

    def __init__(
        self,
        response: type[httpcore.Response] | type[httpcore2.Response],
    ) -> None:
        self._response = response

    def handle_request(self, request: object) -> object:
        return self._response(200, content=b"{}")

    def __enter__(self) -> "_StubPool":
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None


class _StubAsyncPool:
    def __init__(
        self,
        response: type[httpcore.Response] | type[httpcore2.Response],
    ) -> None:
        self._response = response

    async def handle_async_request(self, request: object) -> object:
        return self._response(200, content=b"{}")

    async def __aenter__(self) -> "_StubAsyncPool":
        return self

    async def __aexit__(self, *exc_info: object) -> None:
        return None


@pytest.mark.parametrize(
    "semconv_mode",
    [None, "http", "http/dup"],
    ids=["default", "stable", "dup"],
)
def test_provider_credentials_never_reach_exported_spans(
    semconv_mode: str | None,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """USDA requests carry the API key in the query string, and the httpx
    instrumentation records the request URL under http.url, url.full or both
    depending on OTEL_SEMCONV_STABILITY_OPT_IN. Whatever the mode, for sync
    and async clients alike, and through httpx2 exactly as through httpx, no
    exported span attribute may carry the key — asserted on the spans the
    exporter actually ships, not on the redaction hook in isolation."""
    if semconv_mode is None:
        monkeypatch.delenv("OTEL_SEMCONV_STABILITY_OPT_IN", raising=False)
    else:
        monkeypatch.setenv("OTEL_SEMCONV_STABILITY_OPT_IN", semconv_mode)
    _OpenTelemetrySemanticConventionStability._initialized = False

    exporter = InMemorySpanExporter()
    provider = instrument_application(
        FastAPI(),
        settings=_tracing_settings(),
        exporter=exporter,
        instrument_dependencies=True,
    )
    try:
        with _dependencies_uninstrumented(provider):
            transport = httpx.HTTPTransport()
            transport._pool = _StubPool(httpcore.Response)
            with httpx.Client(transport=transport) as client:
                client.get(f"{BASE}?api_key={SECRET}")
                client.get(BASE)
                client.get(f"{BASE}#api_key={SECRET}")

            transport2 = httpx2.HTTPTransport()
            transport2._pool = _StubPool(httpcore2.Response)
            with httpx2.Client(transport=transport2) as client2:
                client2.get(f"{BASE}?api_key={SECRET}")

            async def one_async_request_each() -> None:
                async_transport = httpx.AsyncHTTPTransport()
                async_transport._pool = _StubAsyncPool(httpcore.Response)
                async with httpx.AsyncClient(transport=async_transport) as client:
                    await client.get(f"{BASE}?api_key={SECRET}")
                async_transport2 = httpx2.AsyncHTTPTransport()
                async_transport2._pool = _StubAsyncPool(httpcore2.Response)
                async with httpx2.AsyncClient(transport=async_transport2) as client2:
                    await client2.get(f"{BASE}?api_key={SECRET}")

            asyncio.run(one_async_request_each())
            provider.force_flush()

        spans = [
            span
            for span in exporter.get_finished_spans()
            if span.kind == SpanKind.CLIENT
        ]
        assert len(spans) == 6
        for span in spans:
            attributes = dict(span.attributes or {})
            for name, value in attributes.items():
                assert SECRET not in str(value), (
                    f"span attribute {name} leaks the provider API key "
                    f"under semconv mode {semconv_mode!r}: {value}"
                )
            url_attributes = {
                name: attributes[name]
                for name in ("http.url", "url.full")
                if name in attributes
            }
            assert url_attributes, f"no URL attribute among {attributes}"
            assert all(value == BASE for value in url_attributes.values())
    finally:
        _OpenTelemetrySemanticConventionStability._initialized = False


class _StructuredMessagePool:
    """Stand in for the SDK's connection pool.

    Answers every request with one structured-output message and keeps the
    requests it was handed, headers included."""

    def __init__(self) -> None:
        self.requests: list[httpcore2.Request] = []

    def handle_request(self, request: httpcore2.Request) -> httpcore2.Response:
        self.requests.append(request)
        return httpcore2.Response(
            200,
            headers=[(b"content-type", b"application/json")],
            content=json.dumps(_structured_message()).encode(),
        )

    def __enter__(self) -> "_StructuredMessagePool":
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None


def _structured_message() -> dict[str, object]:
    extraction = RecipeExtraction(
        title="Toast",
        description="",
        ingredients=[ExtractedIngredient(name="bread", confidence=1)],
        steps=[
            ExtractedStep(
                instruction="Toast the bread.",
                ingredient_indices=[0],
                confidence=1,
            )
        ],
    )
    return {
        "id": "msg_traced",
        "type": "message",
        "role": "assistant",
        "model": "claude-sonnet-4-6",
        "content": [
            {"type": "text", "text": extraction.model_dump_json(by_alias=True)}
        ],
        "stop_reason": "end_turn",
        "stop_sequence": None,
        "usage": {"input_tokens": 12, "output_tokens": 34},
    }


@pytest.mark.parametrize("entry_point", ["api", "worker"])
def test_anthropic_sdk_requests_emit_client_spans(
    entry_point: str,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """anthropic 1.x talks through httpx2 rather than httpx, so patching httpx
    alone left every Claude request out of the traces after the 1.2.0 upgrade,
    and nothing failed. The SDK client is built exactly as the worker builds
    it and driven through the production call site, with only its socket pool
    replaced; the exported CLIENT span and the traceparent header the
    provider would have received are what prove the request was traced."""
    # The SDK's default client honours proxy variables, and a proxied shell
    # would route the request through a mount whose pool is not stubbed.
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"):
        monkeypatch.delenv(name, raising=False)
        monkeypatch.delenv(name.lower(), raising=False)
    exporter = InMemorySpanExporter()
    settings = _tracing_settings()
    if entry_point == "api":
        provider = instrument_application(
            FastAPI(),
            settings=settings,
            exporter=exporter,
            instrument_dependencies=True,
        )
    else:
        worker_provider = instrument_worker(settings, exporter=exporter)
        assert worker_provider is not None
        provider = worker_provider

    with _dependencies_uninstrumented(provider):
        sdk = anthropic.Anthropic(
            api_key="sk-ant-live-key",
            base_url=str(settings.anthropic_base_url),
            timeout=settings.anthropic_timeout_seconds,
        )
        # The SDK builds its own httpx2 transport; only the pool underneath
        # is swapped, so the request travels the same path it does in
        # production up to the socket.
        pool = _StructuredMessagePool()
        sdk._client._transport._pool = pool  # type: ignore[attr-defined]
        response = AnthropicStructuredClient(sdk).parse_recipe(
            model=settings.anthropic_model_id,
            max_tokens=settings.anthropic_max_tokens,
            system="Extract the recipe.",
            user_prompt="Toast the bread.",
        )
        provider.force_flush()

    assert response.parsed_output is not None
    assert response.parsed_output.title == "Toast"
    spans = [
        span for span in exporter.get_finished_spans() if span.kind == SpanKind.CLIENT
    ]
    assert len(spans) == 1, f"expected one CLIENT span, got {spans}"
    attributes = dict(spans[0].attributes or {})
    assert spans[0].name == "POST"
    url_attributes = {
        name: attributes[name]
        for name in ("http.url", "url.full")
        if name in attributes
    }
    assert url_attributes, f"no URL attribute among {attributes}"
    assert all(
        value == f"{settings.anthropic_base_url}v1/messages"
        for value in url_attributes.values()
    )
    [request] = pool.requests
    assert b"traceparent" in {name.lower() for name, _ in request.headers}
