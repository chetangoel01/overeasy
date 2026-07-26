from collections.abc import MutableMapping
from uuid import UUID, uuid4

from fastapi import status
from fastapi.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from ladle.contracts.errors import ErrorCode, ErrorDTO, ErrorEnvelope

_REQUEST_ID_HEADER = "X-Request-ID"


class RequestBodyLimitMiddleware:
    """Bound total HTTP body bytes before request parsing or route execution."""

    def __init__(self, app: ASGIApp, *, maximum_bytes: int) -> None:
        if maximum_bytes <= 0:
            raise ValueError("maximum request body bytes must be positive")
        self._app = app
        self._maximum_bytes = maximum_bytes

    async def __call__(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
    ) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return

        content_length = self._content_length(scope)
        if content_length is None:
            await self._invalid_request(
                scope,
                receive,
                send,
                message="Content-Length is invalid.",
                http_status=status.HTTP_400_BAD_REQUEST,
            )
            return
        if content_length > self._maximum_bytes:
            await self._too_large(scope, receive, send)
            return

        messages: list[Message] = []
        received = 0
        while True:
            message = await receive()
            messages.append(message)
            if message["type"] == "http.disconnect":
                break
            if message["type"] != "http.request":
                continue
            received += len(message.get("body", b""))
            if received > self._maximum_bytes:
                await self._too_large(scope, receive, send)
                return
            if not message.get("more_body", False):
                break

        index = 0

        async def replay() -> Message:
            nonlocal index
            if index < len(messages):
                message = messages[index]
                index += 1
                return message
            return await receive()

        await self._app(scope, replay, send)

    @staticmethod
    def _content_length(scope: Scope) -> int | None:
        values = [
            value
            for name, value in scope.get("headers", [])
            if name.lower() == b"content-length"
        ]
        if not values:
            return 0
        if len(values) != 1:
            return None
        try:
            parsed = int(values[0])
        except ValueError:
            return None
        return parsed if parsed >= 0 else None

    async def _too_large(
        self,
        scope: Scope,
        receive: Receive,
        send: Send,
    ) -> None:
        await self._invalid_request(
            scope,
            receive,
            send,
            message="The request body is too large.",
            http_status=status.HTTP_413_CONTENT_TOO_LARGE,
        )

    @staticmethod
    async def _invalid_request(
        scope: Scope,
        receive: Receive,
        send: Send,
        *,
        message: str,
        http_status: int,
    ) -> None:
        state = scope.get("state")
        request_id = (
            state.get("request_id") if isinstance(state, MutableMapping) else None
        )
        identifier = request_id if isinstance(request_id, UUID) else uuid4()
        envelope = ErrorEnvelope(
            error=ErrorDTO(
                code=ErrorCode.INVALID_REQUEST,
                message=message,
                retryable=False,
                request_id=identifier,
            )
        )
        response = JSONResponse(
            status_code=http_status,
            content=envelope.model_dump(mode="json", by_alias=True),
            headers={_REQUEST_ID_HEADER: str(identifier)},
        )
        await response(scope, receive, send)
