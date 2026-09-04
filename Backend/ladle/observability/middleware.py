import logging
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime
from time import perf_counter
from uuid import UUID, uuid4

from fastapi import FastAPI, Request, Response

from ladle.observability.metrics import MetricsRegistry
from ladle.observability.recent import RecentRequests
from ladle.observability.structured_logging import log_context

X_REQUEST_ID = "X-Request-ID"
LOGGER = logging.getLogger("ladle.http")
# Endpoints polled on a timer rather than requested by a person: the uptime
# probe, and the dashboard polling itself.
_POLLED = frozenset(
    {
        "/health/live",
        "/health/ready",
        "/ops/metrics.json",
        "/ops/readiness.json",
        "/ops/requests.json",
    }
)


def is_loggable(route: str, status_code: int) -> bool:
    """Whether a completed request is worth a line in the log.

    The uptime probe is 98.5% of requests on the deployed host, and an open
    dashboard adds twelve polls a minute of its own. Logging every success
    would fill the 30 MB the json-file driver keeps with machines talking to
    themselves and evict the traffic an operator actually needs. A poll that
    FAILS is the opposite — it is the first sign of a dependency going, so
    those are kept. Metrics still count every request either way.
    """

    return status_code >= 400 or route not in _POLLED


def install_request_middleware(
    application: FastAPI,
    *,
    metrics: MetricsRegistry,
    recent: RecentRequests | None = None,
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
        if not is_loggable(str(route_path), status_code):
            return
        LOGGER.info("HTTP request completed", extra=event)
        if recent is not None:
            # `route_path` is Starlette's matched template, never the requested
            # URL, which is what keeps recipe IDs out of the stored entry.
            recent.record(
                {
                    "at": datetime.now(tz=UTC).isoformat(),
                    "request_id": event["request_id"],
                    "method": event["method"],
                    "route": event["route"],
                    "status_code": status_code,
                    "duration_ms": event["duration_ms"],
                    **(
                        {"user_safe_id": safe_user}
                        if isinstance(safe_user, str)
                        else {}
                    ),
                }
            )
