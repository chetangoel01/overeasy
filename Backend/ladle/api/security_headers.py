"""Set non-negotiable response headers at the outer API boundary."""

from collections.abc import Mapping

from starlette.datastructures import MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class SecurityHeadersMiddleware:
    _INTERACTIVE_DOCS_POLICY = (
        "default-src 'none'; script-src 'self' 'unsafe-inline'; "
        "style-src 'self'; img-src 'self' data:; connect-src 'self'; "
        "frame-ancestors 'none'; base-uri 'none'"
    )

    def __init__(
        self,
        app: ASGIApp,
        *,
        production: bool,
        interactive_docs: bool = False,
    ) -> None:
        self._app = app
        self._headers = self.headers(production=production)
        self._interactive_docs = interactive_docs

    @staticmethod
    def headers(*, production: bool) -> Mapping[str, str]:
        values = {
            "Cache-Control": "no-store",
            "Content-Security-Policy": (
                "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
            ),
            "Permissions-Policy": "camera=(), geolocation=(), microphone=()",
            "Referrer-Policy": "no-referrer",
            "X-Content-Type-Options": "nosniff",
            "X-Frame-Options": "DENY",
        }
        if production:
            values["Strict-Transport-Security"] = (
                "max-age=63072000; includeSubDomains; preload"
            )
        return values

    async def __call__(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
    ) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        async def add_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                response_headers = MutableHeaders(scope=message)
                for name, value in self._headers.items():
                    if (
                        name == "Content-Security-Policy"
                        and self._interactive_docs
                        and scope["path"] == "/docs"
                    ):
                        value = self._INTERACTIVE_DOCS_POLICY
                    response_headers.setdefault(name, value)
            await send(message)

        await self._app(scope, receive, add_headers)
