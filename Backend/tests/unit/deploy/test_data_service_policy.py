from pathlib import Path


def test_local_redis_matches_the_documented_durability_contract() -> None:
    compose = (Path(__file__).parents[3] / "docker-compose.yml").read_text()

    for option in (
        "--appendonly",
        "--appendfsync",
        "everysec",
        "--maxmemory-policy",
        "noeviction",
        "--stop-writes-on-bgsave-error",
    ):
        assert option in compose


def test_local_object_storage_applies_versioning_and_lifecycle_policy() -> None:
    compose = (Path(__file__).parents[3] / "docker-compose.yml").read_text()

    assert "ladle.infrastructure.object_storage_init" in compose
    assert "./deploy/object-storage-lifecycle.json:" in compose
