from collections import Counter
from threading import Lock

_CACHE_DISPOSITIONS = frozenset(
    {"hit", "leader", "follower", "bypass", "recheck", "negative"}
)
_PROVIDERS = frozenset(
    {
        "free",
        "whisper",
        "supadata",
        "soscripted",
        "serverFallback",
        "claude",
        "apple",
    }
)
_PROVIDER_OUTCOMES = frozenset(
    {"success", "failure", "fallback", "circuitOpen", "quota", "auth", "timeout"}
)
_JOB_STATUSES = frozenset({"parsing", "ready", "needsReview", "failed"})
_SOURCES = frozenset({"youtube", "tiktok", "instagram", "other"})
_SYNC_OUTCOMES = frozenset({"success", "conflict", "failure"})
_HTTP_METHODS = frozenset({"GET", "POST", "PUT", "DELETE", "PATCH", "OPTIONS"})


class MetricsRegistry:
    def __init__(self) -> None:
        self._values: Counter[tuple[str, tuple[tuple[str, str], ...]]] = Counter()
        self._lock = Lock()

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

    def record_http(self, method: str, route: str, status_code: int) -> None:
        self._require(method, _HTTP_METHODS)
        if not route.startswith("/") and route != "unmatched":
            raise ValueError("HTTP route labels must be route templates")
        status_group = f"{status_code // 100}xx"
        self._increment(
            "ladle_http_requests_total",
            method=method,
            route=route,
            status=status_group,
        )

    def render(self) -> str:
        with self._lock:
            items = sorted(self._values.items())
        lines: list[str] = []
        current_name: str | None = None
        for (name, labels), value in items:
            if name != current_name:
                lines.append(f"# TYPE {name} counter")
                current_name = name
            rendered_labels = ",".join(
                f'{key}="{self._escape(label)}"' for key, label in labels
            )
            suffix = f"{{{rendered_labels}}}" if rendered_labels else ""
            lines.append(f"{name}{suffix} {value}")
        return "\n".join(lines) + ("\n" if lines else "")

    def _increment(self, name: str, **labels: str) -> None:
        key = (name, tuple(sorted(labels.items())))
        with self._lock:
            self._values[key] += 1

    def _require(self, value: str, allowed: frozenset[str]) -> None:
        if value not in allowed:
            raise ValueError(f"unbounded metric label: {value}")

    def _escape(self, value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
