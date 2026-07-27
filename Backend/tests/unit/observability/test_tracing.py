from fastapi import FastAPI
from fastapi.testclient import TestClient
from opentelemetry.sdk.trace.export.in_memory_span_exporter import (
    InMemorySpanExporter,
)

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
