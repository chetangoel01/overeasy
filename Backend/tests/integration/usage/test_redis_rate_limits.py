from datetime import timedelta

import pytest
from redis import Redis
from testcontainers.redis import RedisContainer

from ladle.api.rate_limits import (
    RateLimitCheck,
    RateLimitExceeded,
    RedisTokenBucketBackend,
)


@pytest.mark.integration
def test_redis_rate_limit_is_shared_and_checks_all_dimensions_atomically() -> None:
    with RedisContainer("redis:7.4-alpine") as container:
        url = (
            f"redis://{container.get_container_host_ip()}:"
            f"{container.get_exposed_port(6379)}"
        )
        first = RedisTokenBucketBackend(Redis.from_url(url), prefix="test:one")
        second = RedisTokenBucketBackend(Redis.from_url(url), prefix="test:one")
        shared = RateLimitCheck(
            bucket="guest-ip",
            identity="203.0.113.8",
            capacity=2,
            period=timedelta(minutes=1),
        )

        first.enforce((shared,))
        second.enforce((shared,))
        with pytest.raises(RateLimitExceeded) as rejected:
            first.enforce((shared,))

        assert 1 <= rejected.value.retry_after_seconds <= 30

        constrained = RateLimitCheck(
            bucket="import-user",
            identity="user-1",
            capacity=1,
            period=timedelta(hours=1),
        )
        untouched = RateLimitCheck(
            bucket="import-ip",
            identity="198.51.100.4",
            capacity=1,
            period=timedelta(hours=1),
        )
        first.enforce((constrained,))
        with pytest.raises(RateLimitExceeded):
            first.enforce((constrained, untouched))

        # A rejected multi-dimensional request must not consume an otherwise
        # available bucket.
        first.enforce((untouched,))
