import pytest

from ladle.api.__main__ import main, port_from_environment


def test_api_port_uses_platform_port_with_a_safe_default() -> None:
    assert port_from_environment({}) == 4111
    assert port_from_environment({"PORT": "5432"}) == 5432


@pytest.mark.parametrize("value", ["", "not-a-port", "0", "65536"])
def test_api_port_rejects_invalid_values(value: str) -> None:
    with pytest.raises(ValueError, match="PORT"):
        port_from_environment({"PORT": value})


def test_uvicorn_access_log_is_off_so_the_ops_token_never_reaches_stdout(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    # The dashboard token arrives once as a query parameter, and uvicorn's
    # access line would print the whole request target to the container log.
    captured: dict[str, object] = {}

    def record(application: str, **options: object) -> None:
        captured.update(options)

    monkeypatch.setattr("ladle.api.__main__.uvicorn.run", record)
    main()

    assert captured["access_log"] is False
    assert captured["proxy_headers"] is True
