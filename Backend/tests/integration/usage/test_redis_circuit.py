from datetime import timedelta

import pytest
from redis import Redis
from testcontainers.redis import RedisContainer

from ladle.acquisition.errors import ProviderTransientError
from ladle.usage.circuit import CircuitOpen, RedisCircuitBreaker


@pytest.mark.integration
def test_provider_circuit_state_is_shared_across_workers() -> None:
    with RedisContainer("redis:7.4-alpine") as container:
        url = (
            f"redis://{container.get_container_host_ip()}:"
            f"{container.get_exposed_port(6379)}/0"
        )
        first = RedisCircuitBreaker(
            Redis.from_url(url),
            failure_threshold=2,
            cooldown=timedelta(minutes=5),
            prefix="test:circuit",
        )
        second = RedisCircuitBreaker(
            Redis.from_url(url),
            failure_threshold=2,
            cooldown=timedelta(minutes=5),
            prefix="test:circuit",
        )

        first.record_failure("supadata", ProviderTransientError())
        second.before_call("supadata")
        second.record_failure("supadata", ProviderTransientError())
        with pytest.raises(CircuitOpen):
            first.before_call("supadata")

        second.record_success("supadata")
        first.before_call("supadata")
