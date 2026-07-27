from dataclasses import dataclass
from datetime import datetime, timedelta
from hashlib import sha256
from typing import Protocol, cast

from ladle.acquisition.errors import (
    ProviderAuthenticationError,
    ProviderQuotaError,
)
from ladle.clock import Clock


class CircuitOpen(Exception):
    pass


@dataclass
class _CircuitState:
    failures: int = 0
    open_until: datetime | None = None


class CircuitBreaker:
    def __init__(
        self,
        *,
        clock: Clock,
        failure_threshold: int,
        cooldown: timedelta,
    ) -> None:
        if failure_threshold <= 0:
            raise ValueError("failure threshold must be positive")
        self._clock = clock
        self._failure_threshold = failure_threshold
        self._cooldown = cooldown
        self._states: dict[str, _CircuitState] = {}

    def before_call(self, provider: str) -> None:
        state = self._states.setdefault(provider, _CircuitState())
        if state.open_until is None:
            return
        if state.open_until > self._clock.now():
            raise CircuitOpen(f"{provider} circuit is open")
        state.open_until = None

    def record_success(self, provider: str) -> None:
        self._states[provider] = _CircuitState()

    def record_failure(self, provider: str, error: Exception) -> None:
        state = self._states.setdefault(provider, _CircuitState())
        state.failures += 1
        if isinstance(error, ProviderAuthenticationError | ProviderQuotaError):
            state.failures = self._failure_threshold
        if state.failures >= self._failure_threshold:
            state.open_until = self._clock.now() + self._cooldown


_BEFORE_CALL_SCRIPT = """
local now = redis.call("TIME")
local now_ms = (tonumber(now[1]) * 1000) + math.floor(tonumber(now[2]) / 1000)
local open_until_ms = tonumber(redis.call("HGET", KEYS[1], "open_until_ms"))
if open_until_ms == nil then
    return 0
end
if open_until_ms > now_ms then
    return 1
end
redis.call("DEL", KEYS[1])
return 0
"""

_RECORD_FAILURE_SCRIPT = """
local threshold = tonumber(ARGV[1])
local cooldown_ms = tonumber(ARGV[2])
local force_open = tonumber(ARGV[3])
local now = redis.call("TIME")
local now_ms = (tonumber(now[1]) * 1000) + math.floor(tonumber(now[2]) / 1000)
local failures = redis.call("HINCRBY", KEYS[1], "failures", 1)
if force_open == 1 then
    failures = threshold
    redis.call("HSET", KEYS[1], "failures", failures)
end
if failures >= threshold then
    redis.call("HSET", KEYS[1], "open_until_ms", now_ms + cooldown_ms)
end
redis.call("PEXPIRE", KEYS[1], cooldown_ms * 2)
return failures
"""


class RedisCircuitClient(Protocol):
    def eval(
        self,
        script: str,
        numkeys: int,
        *keys_and_args: str | int,
    ) -> object: ...

    def delete(self, key: str) -> object: ...


class RedisCircuitBreaker(CircuitBreaker):
    """Circuit state shared atomically by every worker through Redis."""

    def __init__(
        self,
        redis: object,
        *,
        failure_threshold: int,
        cooldown: timedelta,
        prefix: str,
    ) -> None:
        if failure_threshold <= 0 or cooldown <= timedelta(0):
            raise ValueError("circuit settings must be positive")
        self._redis = cast(RedisCircuitClient, redis)
        self._failure_threshold = failure_threshold
        self._cooldown_ms = max(1, int(cooldown.total_seconds() * 1000))
        self._prefix = prefix.rstrip(":")

    def before_call(self, provider: str) -> None:
        result = self._redis.eval(
            _BEFORE_CALL_SCRIPT,
            1,
            self._key(provider),
        )
        if int(cast(str | bytes | int | float, result)) > 0:
            raise CircuitOpen(f"{provider} circuit is open")

    def record_success(self, provider: str) -> None:
        self._redis.delete(self._key(provider))

    def record_failure(self, provider: str, error: Exception) -> None:
        force_open = int(
            isinstance(error, ProviderAuthenticationError | ProviderQuotaError)
        )
        self._redis.eval(
            _RECORD_FAILURE_SCRIPT,
            1,
            self._key(provider),
            self._failure_threshold,
            self._cooldown_ms,
            force_open,
        )

    def _key(self, provider: str) -> str:
        digest = sha256(provider.encode("utf-8")).hexdigest()
        return f"{self._prefix}:{{providers}}:{digest}"
