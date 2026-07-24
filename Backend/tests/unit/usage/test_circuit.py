from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest

from ladle.acquisition.errors import ProviderAuthenticationError
from ladle.usage.circuit import CircuitBreaker, CircuitOpen


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def test_auth_failure_opens_then_cooldown_allows_probe() -> None:
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    circuit = CircuitBreaker(
        clock=clock,
        failure_threshold=3,
        cooldown=timedelta(minutes=5),
    )

    circuit.record_failure("supadata", ProviderAuthenticationError())
    with pytest.raises(CircuitOpen):
        circuit.before_call("supadata")

    clock.value += timedelta(minutes=6)
    circuit.before_call("supadata")
    circuit.record_success("supadata")
    circuit.before_call("supadata")
