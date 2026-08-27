import logging
from collections.abc import Sequence
from dataclasses import dataclass
from datetime import timedelta
from hashlib import sha256
from ipaddress import IPv4Address, IPv6Address, ip_address, ip_network
from math import ceil
from typing import Literal, Protocol, cast

from fastapi import Request

from ladle.config import Settings
from ladle.observability.metrics import MetricsRegistry

logger = logging.getLogger(__name__)

IPAddress = IPv4Address | IPv6Address

_TOKEN_BUCKET_SCRIPT = """
local count = #KEYS
local now = redis.call("TIME")
local now_ms = (tonumber(now[1]) * 1000) + math.floor(tonumber(now[2]) / 1000)
local retry_ms = 0
local available = {}

for index = 1, count do
    local capacity = tonumber(ARGV[((index - 1) * 2) + 1])
    local period_ms = tonumber(ARGV[((index - 1) * 2) + 2])
    local state = redis.call("HMGET", KEYS[index], "tokens", "updated_ms")
    local tokens = tonumber(state[1])
    local updated_ms = tonumber(state[2])
    if tokens == nil or updated_ms == nil then
        tokens = capacity
        updated_ms = now_ms
    else
        local elapsed_ms = math.max(0, now_ms - updated_ms)
        tokens = math.min(capacity, tokens + (elapsed_ms * capacity / period_ms))
    end
    available[index] = tokens
    if tokens < 1 then
        retry_ms = math.max(
            retry_ms,
            math.ceil((1 - tokens) * period_ms / capacity)
        )
    end
end

if retry_ms > 0 then
    return math.max(1, math.ceil(retry_ms / 1000))
end

for index = 1, count do
    local period_ms = tonumber(ARGV[((index - 1) * 2) + 2])
    redis.call(
        "HSET",
        KEYS[index],
        "tokens",
        available[index] - 1,
        "updated_ms",
        now_ms
    )
    redis.call("PEXPIRE", KEYS[index], math.ceil(period_ms * 2))
end
return 0
"""


@dataclass(frozen=True)
class RateLimitCheck:
    bucket: str
    identity: str
    capacity: int
    period: timedelta

    def __post_init__(self) -> None:
        if self.capacity <= 0 or self.period <= timedelta(0):
            raise ValueError("rate limits require a positive capacity and period")


class RateLimitExceeded(Exception):
    def __init__(self, retry_after_seconds: int) -> None:
        self.retry_after_seconds = max(1, retry_after_seconds)
        super().__init__("rate limit exceeded")


class RateLimitBackendUnavailable(Exception):
    """The limiter could not be consulted at all.

    Distinct from `RateLimitExceeded`, which is an answer. This one means
    there was no answer, and callers degrade rather than reject.
    """


class RateLimitBackend(Protocol):
    def retry_after(self, checks: Sequence[RateLimitCheck]) -> int | None: ...


class RedisScriptClient(Protocol):
    def eval(
        self,
        script: str,
        numkeys: int,
        *keys_and_args: str | int,
    ) -> object: ...


class NullRateLimitBackend:
    def retry_after(self, checks: Sequence[RateLimitCheck]) -> int | None:
        del checks
        return None


class RedisTokenBucketBackend:
    """Atomically consumes every identity dimension in one Redis script."""

    def __init__(self, redis: object, *, prefix: str) -> None:
        self._redis = cast(RedisScriptClient, redis)
        self._prefix = prefix.rstrip(":")

    def retry_after(self, checks: Sequence[RateLimitCheck]) -> int | None:
        if not checks:
            return None
        keys = [self._key(check) for check in checks]
        arguments: list[int] = []
        for check in checks:
            arguments.extend(
                [
                    check.capacity,
                    max(1, ceil(check.period.total_seconds() * 1000)),
                ]
            )
        try:
            result = self._redis.eval(
                _TOKEN_BUCKET_SCRIPT,
                len(keys),
                *keys,
                *arguments,
            )
        except Exception as error:
            # Redis client failures are provider-specific, so they are typed
            # here rather than leaking out of the limiter.
            raise RateLimitBackendUnavailable(
                "rate-limit store is unreachable"
            ) from error
        if not isinstance(result, str | bytes | int | float):
            raise RuntimeError("Redis returned an invalid rate-limit result")
        seconds = int(result)
        return seconds if seconds > 0 else None

    def enforce(self, checks: Sequence[RateLimitCheck]) -> None:
        retry_after = self.retry_after(checks)
        if retry_after is not None:
            raise RateLimitExceeded(retry_after)

    def _key(self, check: RateLimitCheck) -> str:
        identity = sha256(check.identity.encode("utf-8")).hexdigest()
        # The shared hash tag keeps multi-dimensional scripts compatible with
        # Redis Cluster while the digest keeps user identifiers out of Redis.
        return f"{self._prefix}:{{buckets}}:{check.bucket}:{identity}"


class ClientIPResolver:
    def __init__(self, trusted_proxy_cidrs: str) -> None:
        self._trusted = tuple(
            ip_network(value.strip(), strict=False)
            for value in trusted_proxy_cidrs.split(",")
            if value.strip()
        )

    def resolve(self, request: Request) -> str:
        peer = self._parse(request.client.host if request.client is not None else None)
        if peer is None:
            return "unknown"
        if not self._is_trusted(peer):
            return str(peer)

        forwarded = request.headers.get("x-forwarded-for")
        if forwarded is None:
            return str(peer)
        chain = [self._parse(value.strip()) for value in forwarded.split(",")]
        if not chain or any(value is None for value in chain):
            return str(peer)
        addresses = [value for value in chain if value is not None] + [peer]
        for address in reversed(addresses):
            if not self._is_trusted(address):
                return str(address)
        return str(addresses[0])

    def _is_trusted(self, address: IPAddress) -> bool:
        return any(address in network for network in self._trusted)

    @staticmethod
    def _parse(value: str | None) -> IPAddress | None:
        try:
            return ip_address(value) if value is not None else None
        except ValueError:
            return None


class RateLimitService:
    def __init__(
        self,
        backend: RateLimitBackend,
        *,
        client_ips: ClientIPResolver,
        metrics: MetricsRegistry | None = None,
    ) -> None:
        self._backend = backend
        self._client_ips = client_ips
        self._metrics = metrics

    def client_ip(self, request: Request) -> str:
        return self._client_ips.resolve(request)

    def enforce(self, checks: Sequence[RateLimitCheck]) -> None:
        try:
            retry_after = self._backend.retry_after(checks)
        except RateLimitBackendUnavailable:
            # enforce() runs before call_next on every request, so refusing
            # here would turn a limiter blip into a total API outage —
            # including the dependency-free liveness probe, which an
            # orchestrator reads as a dead container. Serve the request and
            # say so; the limiter is a guard, not the service.
            logger.warning(
                "rate limit store unavailable; serving request unlimited",
                extra={"buckets": sorted({check.bucket for check in checks})},
            )
            return
        if retry_after is not None:
            if self._metrics is not None:
                for check in checks:
                    self._metrics.record_rate_limit(check.bucket)
            raise RateLimitExceeded(retry_after)


@dataclass(frozen=True)
class RateLimitPolicies:
    global_per_minute: int
    attestation_ip_per_hour: int
    attestation_installation_per_hour: int
    guest_ip_per_hour: int
    guest_installation_per_day: int
    refresh_ip_per_minute: int
    refresh_installation_per_minute: int
    apple_ip_per_hour: int
    apple_user_per_hour: int
    import_ip_per_hour: int
    import_installation_per_hour: int
    import_user_per_hour: int
    recipe_mutation_user_per_minute: int
    sync_user_per_minute: int

    @classmethod
    def from_settings(cls, settings: Settings) -> "RateLimitPolicies":
        return cls(
            global_per_minute=settings.rate_limit_global_per_minute,
            attestation_ip_per_hour=settings.rate_limit_attestation_ip_per_hour,
            attestation_installation_per_hour=(
                settings.rate_limit_attestation_installation_per_hour
            ),
            guest_ip_per_hour=settings.rate_limit_guest_ip_per_hour,
            guest_installation_per_day=(settings.rate_limit_guest_installation_per_day),
            refresh_ip_per_minute=settings.rate_limit_refresh_ip_per_minute,
            refresh_installation_per_minute=(
                settings.rate_limit_refresh_installation_per_minute
            ),
            apple_ip_per_hour=settings.rate_limit_apple_ip_per_hour,
            apple_user_per_hour=settings.rate_limit_apple_user_per_hour,
            import_ip_per_hour=settings.rate_limit_import_ip_per_hour,
            import_installation_per_hour=(
                settings.rate_limit_import_installation_per_hour
            ),
            import_user_per_hour=settings.rate_limit_import_user_per_hour,
            recipe_mutation_user_per_minute=(
                settings.rate_limit_recipe_mutation_user_per_minute
            ),
            sync_user_per_minute=settings.rate_limit_sync_user_per_minute,
        )

    def global_request(self) -> tuple[RateLimitCheck, ...]:
        return (self._check("global", "all", self.global_per_minute, minutes=1),)

    def attestation_challenge(
        self,
        ip: str,
        installation: str,
    ) -> tuple[RateLimitCheck, ...]:
        return (
            self._check("attestation:ip", ip, self.attestation_ip_per_hour, hours=1),
            self._check(
                "attestation:installation",
                installation,
                self.attestation_installation_per_hour,
                hours=1,
            ),
        )

    def guest(self, ip: str, installation: str) -> tuple[RateLimitCheck, ...]:
        return (
            self._check("guest:ip", ip, self.guest_ip_per_hour, hours=1),
            self._check(
                "guest:installation",
                installation,
                self.guest_installation_per_day,
                days=1,
            ),
        )

    def refresh(self, ip: str, installation: str) -> tuple[RateLimitCheck, ...]:
        return (
            self._check("refresh:ip", ip, self.refresh_ip_per_minute, minutes=1),
            self._check(
                "refresh:installation",
                installation,
                self.refresh_installation_per_minute,
                minutes=1,
            ),
        )

    def apple(self, ip: str, user: str) -> tuple[RateLimitCheck, ...]:
        return (
            self._check("apple:ip", ip, self.apple_ip_per_hour, hours=1),
            self._check("apple:user", user, self.apple_user_per_hour, hours=1),
        )

    def google(self, ip: str, user: str) -> tuple[RateLimitCheck, ...]:
        return (
            self._check("google:ip", ip, self.apple_ip_per_hour, hours=1),
            self._check("google:user", user, self.apple_user_per_hour, hours=1),
        )

    def import_request(
        self,
        operation: Literal["submit", "retry"],
        ip: str,
        installation: str,
        user: str,
    ) -> tuple[RateLimitCheck, ...]:
        prefix = f"import-{operation}"
        return (
            self._check(f"{prefix}:ip", ip, self.import_ip_per_hour, hours=1),
            self._check(
                f"{prefix}:installation",
                installation,
                self.import_installation_per_hour,
                hours=1,
            ),
            self._check(
                f"{prefix}:user",
                user,
                self.import_user_per_hour,
                hours=1,
            ),
        )

    def recipe_mutation(self, user: str) -> tuple[RateLimitCheck, ...]:
        return (
            self._check(
                "recipe-mutation:user",
                user,
                self.recipe_mutation_user_per_minute,
                minutes=1,
            ),
        )

    def sync_poll(self, user: str) -> tuple[RateLimitCheck, ...]:
        return (self._check("sync:user", user, self.sync_user_per_minute, minutes=1),)

    @staticmethod
    def _check(
        bucket: str,
        identity: str,
        capacity: int,
        **period: int,
    ) -> RateLimitCheck:
        return RateLimitCheck(
            bucket=bucket,
            identity=identity,
            capacity=capacity,
            period=timedelta(**period),
        )
