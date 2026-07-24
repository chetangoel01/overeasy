from typing import Protocol, cast

from fastapi import APIRouter, Request, Response, status
from fastapi.responses import JSONResponse, PlainTextResponse
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from ladle.observability.metrics import MetricsRegistry

router = APIRouter(tags=["operations"])


class ReadinessProbe(Protocol):
    def check(self) -> None: ...


class DatabaseReadinessProbe:
    def __init__(self, sessions: sessionmaker[Session]) -> None:
        self._sessions = sessions

    def check(self) -> None:
        with self._sessions() as database:
            database.execute(text("SELECT 1"))


class RedisPing(Protocol):
    def ping(self) -> object: ...


class RedisReadinessProbe:
    def __init__(self, redis: RedisPing) -> None:
        self._redis = redis

    def check(self) -> None:
        if not self._redis.ping():
            raise RuntimeError("Redis ping failed")


class StorageHealth(Protocol):
    def exists(self, key: str) -> bool: ...


class StorageReadinessProbe:
    def __init__(self, storage: StorageHealth) -> None:
        self._storage = storage

    def check(self) -> None:
        self._storage.exists("__ladle_readiness__")


class ReadinessService:
    def __init__(self, probes: dict[str, ReadinessProbe]) -> None:
        self._probes = dict(sorted(probes.items()))

    def check(self) -> tuple[bool, dict[str, str]]:
        checks: dict[str, str] = {}
        for name, probe in self._probes.items():
            try:
                probe.check()
            except Exception:
                checks[name] = "unavailable"
            else:
                checks[name] = "ready"
        return all(value == "ready" for value in checks.values()), checks


@router.get("/health/live")
def live() -> dict[str, str]:
    return {"status": "live"}


@router.get("/health/ready", response_model=None)
def ready(request: Request) -> Response:
    readiness = cast(ReadinessService, request.app.state.readiness)
    healthy, checks = readiness.check()
    return JSONResponse(
        status_code=(
            status.HTTP_200_OK if healthy else status.HTTP_503_SERVICE_UNAVAILABLE
        ),
        content={
            "status": "ready" if healthy else "notReady",
            "checks": checks,
        },
    )


@router.get("/metrics", response_class=PlainTextResponse)
def metrics(request: Request) -> str:
    registry = cast(MetricsRegistry, request.app.state.metrics)
    return registry.render()
