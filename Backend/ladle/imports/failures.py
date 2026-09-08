"""One retry policy shared by orchestration and the Celery task."""

import httpx
from billiard.exceptions import SoftTimeLimitExceeded  # type: ignore[import-untyped]
from kombu.exceptions import (  # type: ignore[import-untyped]
    OperationalError as KombuOperationalError,
)
from redis.exceptions import RedisError
from sqlalchemy.exc import (
    InterfaceError as SQLAlchemyInterfaceError,
)
from sqlalchemy.exc import (
    OperationalError as SQLAlchemyOperationalError,
)
from sqlalchemy.exc import (
    TimeoutError as SQLAlchemyTimeoutError,
)

from ladle.acquisition.errors import ProviderTransientError
from ladle.cache.claims import ClaimLost

_RETRYABLE_IMPORT_FAILURES = (
    TimeoutError,
    ConnectionError,
    SoftTimeLimitExceeded,
    httpx.TransportError,
    RedisError,
    KombuOperationalError,
    SQLAlchemyInterfaceError,
    SQLAlchemyOperationalError,
    SQLAlchemyTimeoutError,
    ProviderTransientError,
    ClaimLost,
)


def is_retryable_import_failure(error: BaseException) -> bool:
    """Classify only operational failures that can succeed without code changes."""

    current: BaseException | None = error
    seen: set[int] = set()
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, _RETRYABLE_IMPORT_FAILURES):
            return True
        current = current.__cause__ or current.__context__
    return False
