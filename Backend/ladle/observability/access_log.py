"""Keep credentials that ride in a request target out of the access log.

Uvicorn logs the raw request target, query string included. The operator
dashboard hands its token over once as `?token=`, because a browser cannot
attach a bearer header to a typed URL, and that one line was enough to write
the token into the container's json-file log.

Production disables the access log outright in the Compose command, which is
the actual guarantee. This filter is what survives that command being edited:
it is installed when the ASGI application module is imported, so it applies
however the server was started.
"""

import logging

_ACCESS_LOGGER = "uvicorn.access"
_UVICORN_ACCESS_ARGUMENT_COUNT = 5
_TARGET_POSITION = 2


class QueryStringRedactingFilter(logging.Filter):
    """Strip the query string before the record is ever formatted."""

    def filter(self, record: logging.LogRecord) -> bool:
        arguments = record.args
        if (
            not isinstance(arguments, tuple)
            or len(arguments) != _UVICORN_ACCESS_ARGUMENT_COUNT
        ):
            return True
        target = arguments[_TARGET_POSITION]
        if isinstance(target, str) and "?" in target:
            record.args = (
                *arguments[:_TARGET_POSITION],
                target.partition("?")[0],
                *arguments[_TARGET_POSITION + 1 :],
            )
        return True


def install_access_log_redaction() -> None:
    """Attach the filter once, whatever imports this module."""

    logger = logging.getLogger(_ACCESS_LOGGER)
    if any(
        isinstance(existing, QueryStringRedactingFilter) for existing in logger.filters
    ):
        return
    logger.addFilter(QueryStringRedactingFilter())
