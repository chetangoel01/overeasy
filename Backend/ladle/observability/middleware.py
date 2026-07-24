from collections.abc import Awaitable, Callable
from uuid import UUID, uuid4

from fastapi import FastAPI, Request, Response

from ladle.observability.metrics import MetricsRegistry

X_REQUEST_ID = "X-Request-ID"


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
        response = await call_next(request)
        response.headers[X_REQUEST_ID] = str(identifier)
        route = request.scope.get("route")
        route_path = getattr(route, "path", "unmatched")
        metrics.record_http(request.method, str(route_path), response.status_code)
        return response
