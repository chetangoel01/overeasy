import logging
from datetime import timedelta
from uuid import UUID, uuid4

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException

from ladle.contracts.errors import (
    ErrorCode,
    ErrorDetails,
    ErrorDTO,
    ErrorEnvelope,
    RateLimitDetails,
)

logger = logging.getLogger(__name__)


def request_id(request: Request) -> UUID:
    value = getattr(request.state, "request_id", None)
    return value if isinstance(value, UUID) else uuid4()


def error_response(
    request: Request,
    *,
    code: ErrorCode,
    message: str,
    http_status: int,
    retryable: bool = False,
    details: ErrorDetails | None = None,
) -> JSONResponse:
    envelope = ErrorEnvelope(
        error=ErrorDTO(
            code=code,
            message=message,
            retryable=retryable,
            request_id=request_id(request),
            details=details,
        )
    )
    return JSONResponse(
        status_code=http_status,
        content=envelope.model_dump(mode="json", by_alias=True),
    )


def _http_error(request: Request, error: HTTPException) -> JSONResponse:
    if error.status_code in {
        status.HTTP_401_UNAUTHORIZED,
        status.HTTP_403_FORBIDDEN,
    }:
        code = ErrorCode.AUTHENTICATION_REQUIRED
        message = "Authentication is required."
    elif error.status_code == status.HTTP_404_NOT_FOUND:
        code = ErrorCode.NOT_FOUND
        message = "The requested resource was not found."
    elif error.status_code == status.HTTP_409_CONFLICT:
        code = ErrorCode.CONFLICT
        message = "The request conflicts with current server state."
    elif error.status_code == status.HTTP_429_TOO_MANY_REQUESTS:
        retry_at = request.app.state.clock.now() + timedelta(minutes=1)
        return error_response(
            request,
            code=ErrorCode.RATE_LIMITED,
            message="Too many requests.",
            retryable=True,
            details=RateLimitDetails(retry_at=retry_at),
            http_status=error.status_code,
        )
    elif error.status_code == status.HTTP_503_SERVICE_UNAVAILABLE:
        code = ErrorCode.PROVIDER_UNAVAILABLE
        message = "The service is temporarily unavailable."
    else:
        code = ErrorCode.INVALID_REQUEST
        message = "The request is invalid."
    return error_response(
        request,
        code=code,
        message=message,
        http_status=error.status_code,
        retryable=error.status_code >= 500,
    )


def install_error_handlers(application: FastAPI) -> None:
    @application.exception_handler(HTTPException)
    async def handle_http_error(
        request: Request,
        error: HTTPException,
    ) -> JSONResponse:
        return _http_error(request, error)

    @application.exception_handler(RequestValidationError)
    async def handle_validation_error(
        request: Request,
        error: RequestValidationError,
    ) -> JSONResponse:
        del error
        return error_response(
            request,
            code=ErrorCode.INVALID_REQUEST,
            message="The request is invalid.",
            http_status=status.HTTP_422_UNPROCESSABLE_CONTENT,
        )

    @application.exception_handler(Exception)
    async def handle_unexpected_error(
        request: Request,
        error: Exception,
    ) -> JSONResponse:
        logger.error(
            "Unhandled API exception",
            extra={
                "request_id": str(request_id(request)),
                "method": request.method,
                "path": request.url.path,
                "exception_type": type(error).__name__,
            },
        )
        return error_response(
            request,
            code=ErrorCode.INTERNAL_ERROR,
            message="An unexpected server error occurred.",
            retryable=True,
            http_status=status.HTTP_500_INTERNAL_SERVER_ERROR,
        )
