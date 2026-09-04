"""A small operator dashboard served by the API itself.

The deployment is one modest VPS behind a shared gateway on an assigned
hostname, so a Prometheus/Grafana pair has nowhere to live: no spare memory
budget and no subdomain to terminate TLS on. The counters that stack would
scrape are already durable in Redis, so the dashboard reads them directly and
renders in the browser.
"""

import hmac
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

from fastapi import APIRouter, HTTPException, Query, Request, Response, status
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse

from ladle.api.routes.health import ReadinessService
from ladle.observability.metrics import MetricsRegistry

router = APIRouter()

OPS_COOKIE = "ladle_ops"
OPS_COOKIE_LIFETIME = 12 * 60 * 60
_PAGE = Path(__file__).with_name("ops_dashboard.html")


class OpsAccessPolicy:
    """Browser-facing access to the dashboard.

    The Prometheus token must never reach a browser, so the dashboard carries
    its own credential with its own blast radius. A browser cannot attach a
    bearer header to a typed URL, so the token arrives once in the query
    string, moves into an HttpOnly cookie, and is absent from every later URL.
    """

    def __init__(self, token: str | None) -> None:
        self._token = token

    def matches(self, supplied: str | None) -> bool:
        if self._token is None:
            return True
        if supplied is None:
            return False
        return hmac.compare_digest(supplied.encode(), self._token.encode())

    def authorize(self, request: Request) -> None:
        if not self.matches(request.cookies.get(OPS_COOKIE)):
            # Hide the dashboard from unauthenticated public scans.
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

    def issue(self, response: Response, *, secure: bool) -> None:
        """`secure` follows the scheme the request arrived on.

        Not the environment: the VPS runs the documented
        `LADLE_ENVIRONMENT=development` exception behind an HTTPS gateway, so
        keying the flag on the environment would hand a real deployment a
        cookie a browser is willing to send in clear. Local development is
        plain HTTP, where a Secure cookie would be dropped instead of stored.
        """

        if self._token is None:
            return
        response.set_cookie(
            OPS_COOKIE,
            self._token,
            max_age=OPS_COOKIE_LIFETIME,
            httponly=True,
            secure=secure,
            samesite="strict",
            path="/ops",
        )


@router.get("/ops", response_class=HTMLResponse)
def dashboard(
    request: Request,
    token: str | None = Query(default=None),
) -> Response:
    policy = cast(OpsAccessPolicy, request.app.state.ops_access)
    if token is not None:
        if not policy.matches(token):
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
        handoff = RedirectResponse("/ops", status_code=status.HTTP_303_SEE_OTHER)
        policy.issue(handoff, secure=request.url.scheme == "https")
        return handoff
    policy.authorize(request)
    return HTMLResponse(_PAGE.read_text(encoding="utf-8"))


@router.get("/ops/metrics.json")
def dashboard_metrics(request: Request) -> Response:
    """The counter snapshot the page polls; it contacts no dependency."""

    policy = cast(OpsAccessPolicy, request.app.state.ops_access)
    policy.authorize(request)
    registry = cast(MetricsRegistry, request.app.state.metrics)
    return JSONResponse(
        {
            "generatedAt": datetime.now(tz=UTC).isoformat(),
            "series": [
                {"name": name, "labels": dict(labels), "value": value}
                for (name, labels), value in sorted(registry.snapshot().items())
            ],
        }
    )


@router.get("/ops/readiness.json")
def dashboard_readiness(request: Request) -> Response:
    """Deliberately separate from the fast poll.

    A readiness check contacts every dependency and wakes a Celery CLI
    process, so it is never worth running at the cadence a live request chart
    wants. The page asks for this one on a slow timer of its own.
    """

    policy = cast(OpsAccessPolicy, request.app.state.ops_access)
    policy.authorize(request)
    readiness = cast(ReadinessService, request.app.state.readiness)
    registry = cast(MetricsRegistry, request.app.state.metrics)
    healthy, checks = readiness.check()
    for component, result in checks.items():
        registry.set_readiness(component, result == "ready")
    return JSONResponse({"healthy": healthy, "checks": checks})
