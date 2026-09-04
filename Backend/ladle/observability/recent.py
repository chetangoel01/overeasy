"""A short, bounded list of recently completed requests.

The counters answer "how much"; this answers "what just happened", which is
what an operator wants when something looks wrong right now.

It deliberately stores request *metadata* only: a field not on the allowlist is
dropped rather than trusted, and the route is Starlette's matched template, so
no body, query string or path identifier reaches it. That keeps this list
outside the promises `docs/privacy-retention-and-key-rotation.md` and the
account deletion flow make about user data — there is nothing here to delete.
"""

import json
from collections import deque
from threading import Lock
from typing import Protocol, cast

# Everything the list is allowed to hold. A field not named here is discarded
# rather than trusted, because the caller is a middleware that also sees bodies.
_ALLOWED_FIELDS = frozenset(
    {
        "at",
        "request_id",
        "method",
        "route",
        "status_code",
        "duration_ms",
        "user_safe_id",
    }
)
_REQUIRED_FIELDS = frozenset({"at", "method", "route", "status_code"})

RecentEntry = dict[str, object]


class RecentBackend(Protocol):
    def push(self, encoded: str, *, limit: int) -> None: ...

    def latest(self, *, limit: int) -> list[str]: ...


class MemoryRecentBackend:
    """For development and tests; a single process keeps its own list."""

    def __init__(self) -> None:
        self._entries: deque[str] = deque()
        self._lock = Lock()

    def push(self, encoded: str, *, limit: int) -> None:
        with self._lock:
            self._entries.appendleft(encoded)
            while len(self._entries) > limit:
                self._entries.pop()

    def latest(self, *, limit: int) -> list[str]:
        with self._lock:
            return list(self._entries)[:limit]


class RedisListClient(Protocol):
    def lpush(self, name: str, *values: str) -> object: ...

    def ltrim(self, name: str, start: int, end: int) -> object: ...

    def lrange(self, name: str, start: int, end: int) -> list[object]: ...


class RedisRecentBackend:
    """One list shared by every API process, trimmed on each write."""

    def __init__(self, redis: object, *, prefix: str) -> None:
        self._redis = cast(RedisListClient, redis)
        self._key = f"{prefix.rstrip(':')}:recent"

    def push(self, encoded: str, *, limit: int) -> None:
        self._redis.lpush(self._key, encoded)
        self._redis.ltrim(self._key, 0, limit - 1)

    def latest(self, *, limit: int) -> list[str]:
        return [
            value.decode("utf-8") if isinstance(value, bytes) else str(value)
            for value in self._redis.lrange(self._key, 0, limit - 1)
        ]


class RecentRequests:
    def __init__(self, *, backend: RecentBackend | None = None, limit: int) -> None:
        if limit <= 0:
            raise ValueError("the recent request list needs a positive limit")
        self._backend = backend or MemoryRecentBackend()
        self._limit = limit

    def record(self, entry: RecentEntry) -> None:
        kept = {key: value for key, value in entry.items() if key in _ALLOWED_FIELDS}
        if not set(kept) >= _REQUIRED_FIELDS:
            return
        # No shape check on the route: `/v1/recipes/discover` and
        # `/v1/recipes/<an id>` are the same string to any inspection, so a
        # check here would only offer false assurance. The guarantee is at the
        # call site, which passes Starlette's matched route template rather
        # than the request URL, and the test that holds it there.
        if not isinstance(kept.get("route"), str):
            return
        self._backend.push(
            json.dumps(kept, separators=(",", ":"), sort_keys=True),
            limit=self._limit,
        )

    def snapshot(self, *, limit: int | None = None) -> list[RecentEntry]:
        wanted = min(limit or self._limit, self._limit)
        entries: list[RecentEntry] = []
        for encoded in self._backend.latest(limit=wanted):
            try:
                decoded = json.loads(encoded)
            except ValueError:
                continue
            if isinstance(decoded, dict):
                entries.append(decoded)
        return entries
