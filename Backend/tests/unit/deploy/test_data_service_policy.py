import json
from pathlib import Path


def test_production_data_services_require_pitr_and_durable_redis() -> None:
    policy_path = (
        Path(__file__).parents[3]
        / "deploy"
        / "operations"
        / "production-data-services.json"
    )
    policy = json.loads(policy_path.read_text())

    postgres = policy["postgresql"]
    assert postgres["automatedBackups"] is True
    assert postgres["backupRetentionDays"] >= 35
    assert postgres["pointInTimeRecovery"] is True
    assert postgres["pitrWindowDays"] >= 7
    assert postgres["encrypted"] is True
    assert postgres["multiAvailabilityZone"] is True
    assert postgres["restoreDrillMaximumAgeDays"] <= 90

    redis = policy["redis"]
    assert redis["appendOnly"] is True
    assert redis["appendFsync"] == "everysec"
    assert redis["maxmemoryPolicy"] == "noeviction"
    assert redis["multiAvailabilityZone"] is True
    assert redis["persistenceRequiredBeforeWrites"] is True


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
