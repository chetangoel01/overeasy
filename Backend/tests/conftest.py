import os
from collections.abc import Iterator

import pytest


@pytest.fixture(autouse=True)
def isolate_ladle_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[None]:
    for name in tuple(key for key in os.environ if key.startswith("LADLE_")):
        monkeypatch.delenv(name, raising=False)
    yield
