import logging

import pytest

from ladle.api.app import create_app
from ladle.config import Settings
from ladle.observability.structured_logging import JSONRedactingFormatter


@pytest.fixture
def restore_root_logging():
    root = logging.getLogger()
    handlers = root.handlers[:]
    level = root.level
    yield
    root.handlers = handlers
    root.setLevel(level)


def test_structured_logging_installs_outside_production(
    restore_root_logging: None,
) -> None:
    # The VPS runs the documented LADLE_ENVIRONMENT=development exception, so a
    # gate on "production" left a real deployment logging nothing per request.
    create_app(
        settings=Settings(
            environment="development",
            structured_logging_enabled=True,
            _env_file=None,
        ),
        readiness_probes={},
    )
    handlers = logging.getLogger().handlers

    assert any(isinstance(h.formatter, JSONRedactingFormatter) for h in handlers)


def test_it_stays_off_when_explicitly_disabled(restore_root_logging: None) -> None:
    before = logging.getLogger().handlers[:]
    create_app(
        settings=Settings(structured_logging_enabled=False, _env_file=None),
        readiness_probes={},
    )

    assert logging.getLogger().handlers == before
