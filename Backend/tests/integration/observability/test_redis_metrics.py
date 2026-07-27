import pytest
from redis import Redis
from testcontainers.redis import RedisContainer

from ladle.observability.metrics import MetricsRegistry, RedisMetricsBackend


@pytest.mark.integration
def test_metrics_are_atomic_shared_and_survive_process_registry_recreation() -> None:
    with RedisContainer("redis:7.4-alpine") as container:
        url = (
            f"redis://{container.get_container_host_ip()}:"
            f"{container.get_exposed_port(6379)}/0"
        )
        first = MetricsRegistry(
            backend=RedisMetricsBackend(Redis.from_url(url), prefix="test:metrics")
        )
        second = MetricsRegistry(
            backend=RedisMetricsBackend(Redis.from_url(url), prefix="test:metrics")
        )

        first.record_job("ready", "youtube")
        second.record_job("ready", "youtube")
        recreated = MetricsRegistry(
            backend=RedisMetricsBackend(Redis.from_url(url), prefix="test:metrics")
        )

        assert (
            'ladle_import_jobs_total{source="youtube",status="ready"} 2'
            in recreated.render()
        )
