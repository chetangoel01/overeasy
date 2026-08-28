import asyncio

import httpcore
import httpx
import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.instrumentation._semconv import (
    _OpenTelemetrySemanticConventionStability,
)
from opentelemetry.instrumentation.celery import CeleryInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)
from opentelemetry.trace import SpanKind

from ladle.config import Settings
from ladle.observability.tracing import instrument_application


def test_fastapi_requests_emit_otlp_compatible_spans() -> None:
    app = FastAPI()

    @app.get("/trace-test")
    def traced() -> dict[str, str]:
        return {"status": "ok"}

    exporter = InMemorySpanExporter()
    provider = instrument_application(
        app,
        settings=Settings(
            tracing_enabled=True,
            tracing_otlp_endpoint="https://telemetry.example.test/v1/traces",
            _env_file=None,
        ),
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
    def handle_request(self, request: httpcore.Request) -> httpcore.Response:
        return httpcore.Response(200, content=b"{}")

    def __enter__(self) -> "_StubPool":
        return self

    def __exit__(self, *exc_info: object) -> None:
        return None


class _StubAsyncPool:
    async def handle_async_request(
        self, request: httpcore.Request
    ) -> httpcore.Response:
        return httpcore.Response(200, content=b"{}")

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
    depending on OTEL_SEMCONV_STABILITY_OPT_IN. Whatever the mode, and for
    sync and async clients alike, no exported span attribute may carry the
    key — asserted on the spans the exporter actually ships, not on the
    redaction hook in isolation."""
    if semconv_mode is None:
        monkeypatch.delenv("OTEL_SEMCONV_STABILITY_OPT_IN", raising=False)
    else:
        monkeypatch.setenv("OTEL_SEMCONV_STABILITY_OPT_IN", semconv_mode)
    _OpenTelemetrySemanticConventionStability._initialized = False

    exporter = InMemorySpanExporter()
    provider = instrument_application(
        FastAPI(),
        settings=Settings(
            tracing_enabled=True,
            tracing_otlp_endpoint="https://telemetry.example.test/v1/traces",
            _env_file=None,
        ),
        exporter=exporter,
        instrument_dependencies=True,
    )
    try:
        transport = httpx.HTTPTransport()
        transport._pool = _StubPool()
        with httpx.Client(transport=transport) as client:
            client.get(f"{BASE}?api_key={SECRET}")
            client.get(BASE)
            client.get(f"{BASE}#api_key={SECRET}")

        async def one_async_request() -> None:
            async_transport = httpx.AsyncHTTPTransport()
            async_transport._pool = _StubAsyncPool()
            async with httpx.AsyncClient(transport=async_transport) as client:
                await client.get(f"{BASE}?api_key={SECRET}")

        asyncio.run(one_async_request())
        provider.force_flush()

        spans = [
            span
            for span in exporter.get_finished_spans()
            if span.kind == SpanKind.CLIENT
        ]
        assert len(spans) == 4
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
        HTTPXClientInstrumentor().uninstrument()
        RedisInstrumentor().uninstrument()
        CeleryInstrumentor().uninstrument()
        provider.shutdown()
        _OpenTelemetrySemanticConventionStability._initialized = False
