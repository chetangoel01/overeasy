import hmac
from collections.abc import Callable
from time import sleep as system_sleep
from typing import Any, Protocol, cast

from fastapi import APIRouter, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse, PlainTextResponse
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from ladle.config import Settings
from ladle.observability.metrics import MetricsRegistry

router = APIRouter(tags=["operations"])


class ReadinessProbe(Protocol):
    def check(self) -> None: ...


class MetricsAccessPolicy:
    def __init__(self, token: str | None) -> None:
        self._token = token

    def authorize(self, authorization: str | None) -> None:
        if self._token is None:
            return
        scheme, _, supplied = (authorization or "").partition(" ")
        if (
            scheme.casefold() != "bearer"
            or not supplied
            or not hmac.compare_digest(supplied, self._token)
        ):
            # Hide the endpoint from unauthenticated public scans.
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)


class DatabaseReadinessProbe:
    def __init__(
        self,
        sessions: sessionmaker[Session],
        *,
        expected_revision: str = "0015",
    ) -> None:
        self._sessions = sessions
        self._expected_revision = expected_revision

    def check(self) -> None:
        with self._sessions() as database:
            database.execute(text("SELECT 1"))
            revision = database.scalar(text("SELECT version_num FROM alembic_version"))
            if revision != self._expected_revision:
                raise RuntimeError(
                    "database migration revision does not match the application"
                )


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


class CeleryInspector(Protocol):
    def ping(self) -> dict[str, Any] | None: ...


class CeleryControl(Protocol):
    def inspect(self, *, timeout: float) -> CeleryInspector: ...


class CeleryWorkerReadinessProbe:
    def __init__(
        self,
        control: CeleryControl,
        *,
        timeout_seconds: float,
    ) -> None:
        self._control = control
        self._timeout = timeout_seconds

    def check(self) -> None:
        workers = self._control.inspect(timeout=self._timeout).ping()
        if not workers:
            raise RuntimeError("no Celery worker answered the readiness ping")


class ProductionConfigurationReadinessProbe:
    def __init__(self, settings: Settings) -> None:
        self._settings = settings

    def check(self) -> None:
        Settings.model_validate(self._settings.model_dump())


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


class StartupDependencyGate:
    def __init__(
        self,
        readiness: ReadinessService,
        *,
        attempts: int,
        delay_seconds: float,
        sleep: Callable[[float], None] = system_sleep,
    ) -> None:
        if attempts <= 0 or delay_seconds <= 0:
            raise ValueError("startup retry settings must be positive")
        self._readiness = readiness
        self._attempts = attempts
        self._delay = delay_seconds
        self._sleep = sleep

    def wait(self) -> None:
        checks: dict[str, str] = {}
        for attempt in range(self._attempts):
            healthy, checks = self._readiness.check()
            if healthy:
                return
            if attempt + 1 < self._attempts:
                self._sleep(self._delay)
        unavailable = ", ".join(
            name for name, result in checks.items() if result != "ready"
        )
        raise RuntimeError(f"startup dependencies unavailable: {unavailable}")


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
    policy = cast(MetricsAccessPolicy, request.app.state.metrics_access)
    policy.authorize(request.headers.get("authorization"))
    registry = cast(MetricsRegistry, request.app.state.metrics)
    readiness = cast(ReadinessService, request.app.state.readiness)
    _, checks = readiness.check()
    for component, result in checks.items():
        registry.set_readiness(component, result == "ready")
    return registry.render()
