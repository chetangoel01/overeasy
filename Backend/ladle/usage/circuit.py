from dataclasses import dataclass
from datetime import datetime, timedelta

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
