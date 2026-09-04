import json
from collections import defaultdict
from threading import Lock
from typing import Protocol, cast

_CACHE_DISPOSITIONS = frozenset(
    {"hit", "leader", "follower", "bypass", "recheck", "negative"}
)
_PROVIDERS = frozenset(
    {
        "free",
        "whisper",
        "vision",
        "thumbnailVision",
        "supadata",
        "soscripted",
        "serverFallback",
        "claude",
        "openrouter",
        "openrouterSearch",
        "anthropic",
        "apple",
        "google",
    }
)
_PROVIDER_OUTCOMES = frozenset(
    {"success", "failure", "fallback", "circuitOpen", "quota", "auth", "timeout"}
)
_JOB_STATUSES = frozenset({"parsing", "ready", "needsReview", "failed"})
_SOURCES = frozenset({"youtube", "tiktok", "instagram", "other"})
_SYNC_OUTCOMES = frozenset({"success", "conflict", "failure", "reset"})
_HTTP_METHODS = frozenset({"GET", "HEAD", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"})
_OTHER_HTTP_METHOD = "OTHER"
_RATE_LIMIT_POLICIES = frozenset(
    {
        "global",
        "attestation:ip",
        "attestation:installation",
        "guest:ip",
        "guest:installation",
        "refresh:ip",
        "refresh:installation",
        "apple:ip",
        "apple:user",
        "google:ip",
        "google:user",
        "import-submit:ip",
        "import-submit:installation",
        "import-submit:user",
        "import-retry:ip",
        "import-retry:installation",
        "import-retry:user",
        "recipe-mutation:user",
        "sync:user",
    }
)
_WORKER_RETRY_REASONS = frozenset(
    {"transient", "workerLost", "providerTimeout", "broker", "unknown"}
)
_CLAIM_OUTCOMES = frozenset({"takeover", "expired", "lost"})
_HTTP_DURATION_BUCKETS = (0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0)
_IMPORT_DURATION_BUCKETS = (5.0, 15.0, 30.0, 60.0, 120.0, 300.0, 600.0, 1200.0)
_OPERATIONAL_GAUGES = frozenset(
    {
        "ladle_queue_depth",
        "ladle_oldest_queued_job_age_seconds",
        "ladle_stuck_jobs",
        "ladle_worker_last_seen_timestamp_seconds",
        "ladle_beat_last_seen_timestamp_seconds",
        "ladle_provider_spend_units",
        "ladle_provider_reserved_units",
        "ladle_dead_letters",
        "ladle_object_deletion_failures",
    }
)
_READINESS_COMPONENTS = frozenset(
    {
        "configuration",
        "database",
        "broker",
        "celeryResult",
        "worker",
        "rateLimitRedis",
        "metricsRedis",
        "storage",
    }
)

MetricKey = tuple[str, tuple[tuple[str, str], ...]]


class MetricsBackend(Protocol):
    def increment(self, key: MetricKey, amount: float) -> None: ...

    def set(self, key: MetricKey, value: float) -> None: ...

    def snapshot(self) -> dict[MetricKey, float]: ...


class MemoryMetricsBackend:
    def __init__(self) -> None:
        self._values: dict[MetricKey, float] = defaultdict(float)
        self._lock = Lock()

    def increment(self, key: MetricKey, amount: float) -> None:
        with self._lock:
            self._values[key] += amount

    def set(self, key: MetricKey, value: float) -> None:
        with self._lock:
            self._values[key] = value

    def snapshot(self) -> dict[MetricKey, float]:
        with self._lock:
            return dict(self._values)


class RedisHashClient(Protocol):
    def hincrbyfloat(self, name: str, key: str, amount: float) -> object: ...

    def hgetall(self, name: str) -> dict[object, object]: ...

    def hset(self, name: str, key: str, value: float) -> object: ...


class RedisMetricsBackend:
    """Durable, atomic counters shared by every API and worker process."""

    def __init__(self, redis: object, *, prefix: str) -> None:
        self._redis = cast(RedisHashClient, redis)
        self._key = f"{prefix.rstrip(':')}:series"

    def increment(self, key: MetricKey, amount: float) -> None:
        self._redis.hincrbyfloat(self._key, _encode_key(key), amount)

    def set(self, key: MetricKey, value: float) -> None:
        self._redis.hset(self._key, _encode_key(key), value)

    def snapshot(self) -> dict[MetricKey, float]:
        values: dict[MetricKey, float] = {}
        for raw_key, raw_value in self._redis.hgetall(self._key).items():
            field = (
                raw_key.decode("utf-8") if isinstance(raw_key, bytes) else str(raw_key)
            )
            value = (
                raw_value.decode("utf-8")
                if isinstance(raw_value, bytes)
                else str(raw_value)
            )
            values[_decode_key(field)] = float(value)
        return values


class MetricsRegistry:
    def __init__(self, *, backend: MetricsBackend | None = None) -> None:
        self._backend = backend or MemoryMetricsBackend()

    def record_cache(self, disposition: str) -> None:
        self._require(disposition, _CACHE_DISPOSITIONS)
        self._increment("ladle_cache_total", disposition=disposition)

    def record_provider(self, provider: str, outcome: str) -> None:
        self._require(provider, _PROVIDERS)
        self._require(outcome, _PROVIDER_OUTCOMES)
        self._increment(
            "ladle_provider_total",
            provider=provider,
            outcome=outcome,
        )

    def record_provider_cost(self, provider: str, billed_units: float) -> None:
        self._require(provider, _PROVIDERS)
        if billed_units < 0:
            raise ValueError("provider billed units cannot be negative")
        self._increment(
            "ladle_provider_billed_units_total",
            amount=billed_units,
            provider=provider,
        )

    def record_job(self, status: str, source: str) -> None:
        self._require(status, _JOB_STATUSES)
        self._require(source, _SOURCES)
        self._increment(
            "ladle_import_jobs_total",
            status=status,
            source=source,
        )

    def record_sync(self, outcome: str) -> None:
        self._require(outcome, _SYNC_OUTCOMES)
        self._increment("ladle_sync_total", outcome=outcome)

    def record_http(
        self,
        method: str,
        route: str,
        status_code: int,
        *,
        duration_seconds: float | None = None,
    ) -> None:
        # Unlike the internal outcome enums, the request method is supplied
        # by the caller. Refusing it would let anyone turn a served request
        # into a 500, so it is folded into a bounded label instead.
        if method not in _HTTP_METHODS:
            method = _OTHER_HTTP_METHOD
        if not route.startswith("/") and route != "unmatched":
            raise ValueError("HTTP route labels must be route templates")
        status_group = f"{status_code // 100}xx"
        self._increment(
            "ladle_http_requests_total",
            method=method,
            route=route,
            status=status_group,
        )
        if duration_seconds is not None:
            self._observe_http(method, route, max(0.0, duration_seconds))

    def record_rate_limit(self, policy: str) -> None:
        self._require(policy, _RATE_LIMIT_POLICIES)
        self._increment("ladle_rate_limit_rejections_total", policy=policy)

    def record_worker_retry(self, reason: str) -> None:
        self._require(reason, _WORKER_RETRY_REASONS)
        self._increment("ladle_worker_retries_total", reason=reason)

    def record_claim(self, outcome: str) -> None:
        self._require(outcome, _CLAIM_OUTCOMES)
        self._increment("ladle_claim_events_total", outcome=outcome)

    def observe_import(self, status: str, duration_seconds: float) -> None:
        self._require(status, _JOB_STATUSES)
        duration = max(0.0, duration_seconds)
        for boundary in _IMPORT_DURATION_BUCKETS:
            if duration <= boundary:
                self._increment(
                    "ladle_import_duration_seconds_bucket",
                    status=status,
                    le=f"{boundary:g}",
                )
        self._increment(
            "ladle_import_duration_seconds_bucket",
            status=status,
            le="+Inf",
        )
        self._increment("ladle_import_duration_seconds_count", status=status)
        self._increment(
            "ladle_import_duration_seconds_sum",
            amount=duration,
            status=status,
        )

    def set_operational(self, name: str, value: float) -> None:
        if name not in _OPERATIONAL_GAUGES:
            raise ValueError(f"unknown operational gauge: {name}")
        self._backend.set((name, ()), value)

    def set_readiness(self, component: str, ready: bool) -> None:
        self._require(component, _READINESS_COMPONENTS)
        self._backend.set(
            ("ladle_readiness", (("component", component),)),
            float(ready),
        )

    def snapshot(self) -> dict[MetricKey, float]:
        """Structured series for callers that should not parse the text format."""
        return self._backend.snapshot()

    def render(self) -> str:
        items = sorted(self._backend.snapshot().items())
        lines: list[str] = []
        current_family: str | None = None
        for (name, labels), value in items:
            family = _metric_family(name)
            if family != current_family:
                lines.append(f"# TYPE {family} {_metric_type(family)}")
                current_family = family
            rendered_labels = ",".join(
                f'{key}="{self._escape(label)}"' for key, label in labels
            )
            suffix = f"{{{rendered_labels}}}" if rendered_labels else ""
            lines.append(f"{name}{suffix} {_render_number(value)}")
        return "\n".join(lines) + ("\n" if lines else "")

    def _observe_http(self, method: str, route: str, duration: float) -> None:
        for boundary in _HTTP_DURATION_BUCKETS:
            if duration <= boundary:
                self._increment(
                    "ladle_http_request_duration_seconds_bucket",
                    method=method,
                    route=route,
                    le=f"{boundary:g}",
                )
        self._increment(
            "ladle_http_request_duration_seconds_bucket",
            method=method,
            route=route,
            le="+Inf",
        )
        self._increment(
            "ladle_http_request_duration_seconds_count",
            method=method,
            route=route,
        )
        self._increment(
            "ladle_http_request_duration_seconds_sum",
            amount=duration,
            method=method,
            route=route,
        )

    def _increment(self, name: str, *, amount: float = 1, **labels: str) -> None:
        key = (name, tuple(sorted(labels.items())))
        self._backend.increment(key, amount)

    @staticmethod
    def _require(value: str, allowed: frozenset[str]) -> None:
        if value not in allowed:
            raise ValueError(f"unbounded metric label: {value}")

    @staticmethod
    def _escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def _encode_key(key: MetricKey) -> str:
    name, labels = key
    return json.dumps([name, labels], separators=(",", ":"))


def _decode_key(value: str) -> MetricKey:
    raw_name, raw_labels = json.loads(value)
    return str(raw_name), tuple((str(label[0]), str(label[1])) for label in raw_labels)


def _metric_family(name: str) -> str:
    for suffix in ("_bucket", "_count", "_sum"):
        if name.endswith(suffix):
            return name.removesuffix(suffix)
    return name


def _metric_type(family: str) -> str:
    if family in {
        "ladle_http_request_duration_seconds",
        "ladle_import_duration_seconds",
    }:
        return "histogram"
    return (
        "gauge"
        if family in _OPERATIONAL_GAUGES or family == "ladle_readiness"
        else "counter"
    )


def _render_number(value: float) -> str:
    return str(int(value)) if value.is_integer() else format(value, ".12g")
