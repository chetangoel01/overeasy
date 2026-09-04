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

from ladle.api.rate_limits import ClientIPResolver
from ladle.api.routes.health import ReadinessService
from ladle.observability.metrics import MetricsRegistry

router = APIRouter()

OPS_COOKIE = "ladle_ops"
OPS_COOKIE_LIFETIME = 12 * 60 * 60
# Set by the gateway from the verified peer certificate, and stripped on every
# other hostname so it can never arrive from a client.
OPS_CLIENT_CERT_HEADER = "X-Ladle-Ops-Client"
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
        if self.certified(request) or self.matches(request.cookies.get(OPS_COOKIE)):
            return
        # Hide the dashboard from unauthenticated public scans.
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)

    @staticmethod
    def certified(request: Request) -> bool:
        """A client certificate the gateway already verified.

        Caddy requires and verifies a certificate against the dashboard's
        private CA before it proxies anything, then overwrites this header with
        the peer's subject; the API hostname strips it. So a non-empty value
        from a trusted proxy is proof, and there is nothing here to re-check.
        Trust for the header itself comes from the same list that decides
        whether X-Forwarded-For is believable.
        """

        subject = request.headers.get(OPS_CLIENT_CERT_HEADER)
        if not subject:
            return False
        client_ips = cast(ClientIPResolver, request.app.state.client_ips)
        return client_ips.is_trusted_peer(request)

    def issue(self, response: Response, *, secure: bool) -> None:
        """`secure` follows the scheme the request arrived on.

        Not the environment: the VPS runs the documented
        `LADLE_ENVIRONMENT=development` exception behind an HTTPS gateway, so
        keying the flag on the environment would hand a real deployment a
        cookie a browser is willing to send in clear. Local development is
        plain HTTP, where a Secure cookie would be dropped instead of stored.
        The caller resolves the scheme through the trusted-proxy list, because
        uvicorn believes forwarded headers from the loopback only.
        """

        if self._token is None:
            return
        response.set_cookie(
            OPS_COOKIE,
            self._token,
            max_age=OPS_COOKIE_LIFETIME,
            httponly=True,
            secure=secure,
            # Lax, not Strict: every dashboard route is a read-only GET, and
            # Strict drops the cookie on any link opened from chat or mail,
            # which reads as the dashboard being broken.
            samesite="lax",
            # Scoped to the site, not to /ops. The dashboard hostname rewrites
            # / to /ops inside Caddy, so the browser's URL stays `/` and a
            # cookie scoped to /ops is never sent back — a bookmark would 404
            # forever while the one-time handoff appeared to work. The
            # dedicated hostname is what isolates this cookie now.
            path="/",
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
        client_ips = cast(ClientIPResolver, request.app.state.client_ips)
        policy.issue(handoff, secure=client_ips.forwarded_scheme(request) == "https")
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
