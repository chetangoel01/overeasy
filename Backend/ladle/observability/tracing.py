from typing import cast
from urllib.parse import urlsplit, urlunsplit

from fastapi import FastAPI
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.celery import CeleryInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import (
    HTTPX2ClientInstrumentor,
    HTTPXClientInstrumentor,
)
from opentelemetry.instrumentation.redis import RedisInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import (
    BatchSpanProcessor,
    SimpleSpanProcessor,
    SpanExporter,
)
from sqlalchemy import Engine

from ladle.config import Settings


def instrument_application(
    application: FastAPI,
    *,
    settings: Settings,
    engine: Engine | None = None,
    exporter: SpanExporter | None = None,
    instrument_dependencies: bool = False,
) -> TracerProvider:
    provider = _provider(settings, exporter=exporter)
    FastAPIInstrumentor.instrument_app(
        application,
        tracer_provider=provider,
        excluded_urls="/health/live,/health/ready,/metrics",
    )
    if instrument_dependencies:
        _install_global_provider(provider)
        _instrument_outbound_http(provider)
        RedisInstrumentor().instrument(tracer_provider=provider)
        CeleryInstrumentor().instrument(  # type: ignore[no-untyped-call]
            tracer_provider=provider
        )
        if engine is not None:
            SQLAlchemyInstrumentor().instrument(
                engine=engine,
                tracer_provider=provider,
            )
    return provider


def instrument_worker(
    settings: Settings,
    *,
    exporter: SpanExporter | None = None,
) -> TracerProvider | None:
    if not settings.tracing_enabled:
        return None
    provider = _provider(settings, exporter=exporter)
    _install_global_provider(provider)
    _instrument_outbound_http(provider)
    RedisInstrumentor().instrument(tracer_provider=provider)
    CeleryInstrumentor().instrument(  # type: ignore[no-untyped-call]
        tracer_provider=provider
    )
    return provider


def instrument_database(engine: Engine, provider: TracerProvider | None) -> None:
    if provider is not None:
        SQLAlchemyInstrumentor().instrument(
            engine=engine,
            tracer_provider=provider,
        )


def _instrument_outbound_http(provider: TracerProvider) -> None:
    # The clients this codebase builds itself use httpx, but the anthropic 1.x
    # SDK talks through httpx2, a separate package that the httpx patch never
    # touches: the 0.117 -> 1.2 upgrade dropped every Claude request from the
    # traces without anything failing. Both packages are patched with the same
    # hooks, rather than aliasing httpx to httpx2 process-wide as the SDK's
    # migration guide suggests, so no direct httpx caller changes behaviour.
    for instrumentor in (HTTPXClientInstrumentor(), HTTPX2ClientInstrumentor()):
        instrumentor.instrument(
            tracer_provider=provider,
            request_hook=_redact_httpx_url,
            async_request_hook=_redact_httpx_url_async,
        )


def _provider(
    settings: Settings,
    *,
    exporter: SpanExporter | None = None,
) -> TracerProvider:
    if not settings.tracing_enabled or settings.tracing_otlp_endpoint is None:
        raise ValueError("tracing requires an OTLP endpoint")
    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": settings.tracing_service_name,
                "deployment.environment.name": settings.environment,
            }
        )
    )
    if exporter is None:
        exporter = cast(
            SpanExporter,
            OTLPSpanExporter(endpoint=str(settings.tracing_otlp_endpoint)),
        )
        provider.add_span_processor(BatchSpanProcessor(exporter))
    else:
        provider.add_span_processor(SimpleSpanProcessor(exporter))
    return provider


def _install_global_provider(provider: TracerProvider) -> None:
    current = trace.get_tracer_provider()
    if type(current).__name__ == "ProxyTracerProvider":
        trace.set_tracer_provider(provider)


def _redact_httpx_url(span: object, request: object) -> None:
    set_attribute = getattr(span, "set_attribute", None)
    url = getattr(request, "url", None)
    if not callable(set_attribute) or url is None:
        return
    parsed = urlsplit(str(url))
    sanitized = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, "", ""))
    # Depending on OTEL_SEMCONV_STABILITY_OPT_IN the instrumentation records
    # the URL as http.url, url.full or both, and its own redaction spares
    # provider credentials like api_key. Overwrite every name it can have
    # used so no semconv mode exports a query string.
    set_attribute("http.url", sanitized)
    set_attribute("url.full", sanitized)


async def _redact_httpx_url_async(span: object, request: object) -> None:
    # Async clients are hooked separately, and only through a genuine
    # coroutine function — a plain callable is silently discarded.
    _redact_httpx_url(span, request)
