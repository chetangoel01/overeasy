import json
import logging
from collections.abc import Iterator
from contextlib import contextmanager
from contextvars import ContextVar
from datetime import UTC, datetime
from typing import Any

from opentelemetry import trace

from ladle.observability.redaction import redact_event

_CONTEXT: ContextVar[dict[str, object] | None] = ContextVar(
    "ladle_log_context",
    default=None,
)
_STANDARD_RECORD_FIELDS = frozenset(
    logging.makeLogRecord({}).__dict__.keys()
    | {
        "asctime",
        "message",
    }
)


@contextmanager
def log_context(**values: object) -> Iterator[None]:
    current = {
        **(_CONTEXT.get() or {}),
        **{key: value for key, value in values.items()},
    }
    token = _CONTEXT.set(current)
    try:
        yield
    finally:
        _CONTEXT.reset(token)


class JSONRedactingFormatter(logging.Formatter):
    """Structured JSON with mandatory sink-boundary secret redaction."""

    def format(self, record: logging.LogRecord) -> str:
        event: dict[str, object] = {
            "timestamp": datetime.fromtimestamp(record.created, UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            **(_CONTEXT.get() or {}),
        }
        event.update(
            {
                key: value
                for key, value in record.__dict__.items()
                if key not in _STANDARD_RECORD_FIELDS
                and key not in {"args", "msg", "exc_info", "exc_text", "stack_info"}
            }
        )
        if record.exc_info is not None:
            exception_class = record.exc_info[0]
            if exception_class is not None:
                event["exception_type"] = exception_class.__name__
            event["exception"] = self.formatException(record.exc_info)
        span_context = trace.get_current_span().get_span_context()
        if span_context.is_valid:
            event["trace_id"] = f"{span_context.trace_id:032x}"
            event["span_id"] = f"{span_context.span_id:016x}"
        return json.dumps(
            redact_event(event),
            default=_json_default,
            separators=(",", ":"),
            sort_keys=True,
        )


def configure_structured_logging(*, level: str) -> None:
    handler = logging.StreamHandler()
    handler.setFormatter(JSONRedactingFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())


def _json_default(value: Any) -> str:
    return str(value)
