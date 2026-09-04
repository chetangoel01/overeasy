import logging
from collections.abc import Awaitable, Callable
from time import perf_counter
from uuid import UUID, uuid4

from fastapi import FastAPI, Request, Response

from ladle.observability.metrics import MetricsRegistry
from ladle.observability.structured_logging import log_context

X_REQUEST_ID = "X-Request-ID"
LOGGER = logging.getLogger("ladle.http")
_UPTIME_PROBES = frozenset({"/health/live", "/health/ready"})


def is_loggable(route: str, status_code: int) -> bool:
    """Whether a completed request is worth a line in the log.

    The uptime probe is 98.5% of requests on the deployed host. Logging every
    success would fill the 30 MB the json-file driver keeps with the poller and
    evict the traffic an operator actually needs. A probe that fails is the
    opposite — it is the first sign of a dependency going, so those are kept.
    Metrics still count every request either way.
    """

    return status_code >= 400 or route not in _UPTIME_PROBES


def install_request_middleware(
    application: FastAPI,
    *,
    metrics: MetricsRegistry,
) -> None:
    @application.middleware("http")
    async def request_context(
        request: Request,
        call_next: Callable[[Request], Awaitable[Response]],
    ) -> Response:
        supplied = request.headers.get(X_REQUEST_ID)
        try:
            identifier = UUID(supplied) if supplied is not None else uuid4()
        except ValueError:
            identifier = uuid4()
        request.state.request_id = identifier
        started = perf_counter()
        try:
            with log_context(request_id=str(identifier)):
                response = await call_next(request)
        except Exception:
            # The handler that turns this into a 500 sits outside this
            # middleware, so without recording it here the requests an
            # operator most needs to see are the ones missing from the
            # metrics and the log entirely.
            record(
                identifier=identifier,
                request=request,
                status_code=500,
                duration=perf_counter() - started,
            )
            raise
        response.headers[X_REQUEST_ID] = str(identifier)
        record(
            identifier=identifier,
            request=request,
            status_code=response.status_code,
            duration=perf_counter() - started,
        )
        return response

    def record(
        *,
        identifier: UUID,
        request: Request,
        status_code: int,
        duration: float,
    ) -> None:
        route = request.scope.get("route")
        route_path = getattr(route, "path", "unmatched")
        metrics.record_http(
            request.method,
            str(route_path),
            status_code,
            duration_seconds=duration,
        )
        safe_user = getattr(request.state, "user_safe_id", None)
        event: dict[str, object] = {
            "request_id": str(identifier),
            "method": request.method,
            "route": str(route_path),
            "status_code": status_code,
            "duration_ms": round(duration * 1000, 3),
            "terminal_result": "success" if status_code < 500 else "failure",
        }
        if isinstance(safe_user, str):
            event["user_safe_id"] = safe_user
        if is_loggable(str(route_path), status_code):
            LOGGER.info("HTTP request completed", extra=event)
