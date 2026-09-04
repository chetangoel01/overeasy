import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from ladle.observability.metrics import MetricsRegistry
from ladle.observability.middleware import install_request_middleware


def build_app(metrics: MetricsRegistry) -> FastAPI:
    application = FastAPI()

    @application.get("/probe")
    def probe() -> dict[str, str]:
        return {"ok": "yes"}

    @application.get("/boom")
    def boom() -> dict[str, str]:
        raise RuntimeError("handler exploded")

    install_request_middleware(application, metrics=metrics)
    return application


def test_head_requests_are_answered_and_counted_under_a_bounded_label() -> None:
    """HEAD is a legitimate method that the allowlist did not carry.

    Recording it raised, and the raise happened after the response had been
    produced — turning whatever the router answered into a 500.
    """
    metrics = MetricsRegistry()
    client = TestClient(build_app(metrics))

    response = client.head("/probe")

    # The router's own answer, not a metrics failure.
    assert response.status_code == 405
    assert 'method="HEAD"' in metrics.render()


def test_an_unrecognised_method_is_folded_rather_than_failing_the_request() -> None:
    metrics = MetricsRegistry()
    client = TestClient(build_app(metrics))

    response = client.request("TRACE", "/probe")

    assert response.status_code != 500
    rendered = metrics.render()
    assert 'method="TRACE"' not in rendered
    assert 'method="OTHER"' in rendered


def test_a_failing_handler_is_still_recorded_and_logged() -> None:
    """Without this the request vanishes from observability entirely.

    call_next was unwrapped, so an unhandled exception skipped the metric and
    the completion log — exactly the requests an operator most needs to see.
    """
    metrics = MetricsRegistry()
    client = TestClient(build_app(metrics), raise_server_exceptions=False)

    with pytest.raises(RuntimeError):
        TestClient(build_app(metrics)).get("/boom")

    response = client.get("/boom")

    assert response.status_code == 500
    assert 'status="5xx"' in metrics.render()


def test_successful_uptime_probes_are_not_logged_but_failing_ones_are() -> None:
    # /health/ready is 98.5% of requests on the deployed host. Logging every
    # success would fill the 30 MB the json-file driver keeps with the poller
    # and evict the traffic an operator actually needs. A probe that fails is
    # exactly the thing worth keeping.
    from ladle.observability.middleware import is_loggable

    assert is_loggable("/health/ready", 200) is False
    assert is_loggable("/health/live", 200) is False
    assert is_loggable("/health/ready", 503) is True
    assert is_loggable("/v1/recipes", 200) is True
    # An open dashboard polls twelve times a minute; same reasoning.
    assert is_loggable("/ops/metrics.json", 200) is False
    assert is_loggable("/ops/metrics.json", 500) is True
    assert is_loggable("/ops/requests.json", 200) is False
