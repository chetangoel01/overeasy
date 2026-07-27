import pytest

from ladle.api.__main__ import port_from_environment


def test_api_port_uses_platform_port_with_a_safe_default() -> None:
    assert port_from_environment({}) == 4111
    assert port_from_environment({"PORT": "5432"}) == 5432


@pytest.mark.parametrize("value", ["", "not-a-port", "0", "65536"])
def test_api_port_rejects_invalid_values(value: str) -> None:
    with pytest.raises(ValueError, match="PORT"):
        port_from_environment({"PORT": value})
