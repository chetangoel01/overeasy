import logging

from ladle.observability.access_log import install_access_log_redaction


def _uvicorn_record(target: str) -> logging.LogRecord:
    # Uvicorn's AccessFormatter unpacks exactly this shape:
    # client_addr, method, full_path, http_version, status_code.
    return logging.makeLogRecord(
        {
            "name": "uvicorn.access",
            "levelno": logging.INFO,
            "msg": '%s - "%s %s HTTP/%s" %d',
            "args": ("172.30.0.3:57764", "GET", target, "1.1", 303),
        }
    )


def test_the_access_log_drops_the_query_string_that_carries_the_token() -> None:
    install_access_log_redaction()
    logger = logging.getLogger("uvicorn.access")
    record = _uvicorn_record("/ops?token=a-real-dashboard-token")

    assert all(entry.filter(record) for entry in logger.filters)
    assert record.args is not None
    assert "a-real-dashboard-token" not in record.getMessage()
    assert record.args[2] == "/ops"


def test_a_target_without_a_query_string_is_left_alone() -> None:
    install_access_log_redaction()
    logger = logging.getLogger("uvicorn.access")
    record = _uvicorn_record("/v1/recipes")

    for entry in logger.filters:
        entry.filter(record)

    assert record.args is not None
    assert record.args[2] == "/v1/recipes"


def test_installing_twice_does_not_stack_filters() -> None:
    install_access_log_redaction()
    before = len(logging.getLogger("uvicorn.access").filters)
    install_access_log_redaction()

    assert len(logging.getLogger("uvicorn.access").filters) == before
