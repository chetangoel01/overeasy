from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest

from ladle.acquisition.errors import ProviderAuthenticationError
from ladle.usage.circuit import CircuitBreaker, CircuitOpen, RedisCircuitBreaker


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


@dataclass
class RecordingRedis:
    results: list[int]
    evaluations: list[tuple[Any, ...]] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)

    def eval(
        self,
        script: str,
        numkeys: int,
        *keys_and_args: str | int,
    ) -> int:
        self.evaluations.append((script, numkeys, *keys_and_args))
        return self.results.pop(0)

    def delete(self, key: str) -> int:
        self.deleted.append(key)
        return 1


def test_redis_circuit_shares_atomic_open_state_without_plain_provider_keys() -> None:
    redis = RecordingRedis(results=[1, 0])
    circuit = RedisCircuitBreaker(
        redis,
        failure_threshold=3,
        cooldown=timedelta(minutes=5),
        prefix="ladle:circuit:v1",
    )

    with pytest.raises(CircuitOpen):
        circuit.before_call("provider-secret-name")
    circuit.record_failure("provider-secret-name", ProviderAuthenticationError())
    circuit.record_success("provider-secret-name")

    assert len(redis.evaluations) == 2
    assert all(call[1] == 1 for call in redis.evaluations)
    key = str(redis.evaluations[0][2])
    assert key.startswith("ladle:circuit:v1:{providers}:")
    assert "provider-secret-name" not in key
    assert redis.deleted == [key]
