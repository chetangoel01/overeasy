from pathlib import Path

import yaml


def test_production_migration_is_one_shot_and_gates_rollout() -> None:
    profile = Path(__file__).parents[3] / "deploy" / "vps" / "docker-compose.yml"
    services = yaml.safe_load(profile.read_text())["services"]

    assert services["migrate"]["restart"] == "no"
    assert "alembic" in services["migrate"]["command"][0]
    assert services["api"]["depends_on"]["migrate"] == {
        "condition": "service_completed_successfully"
    }
    assert services["worker"]["depends_on"]["migrate"] == {
        "condition": "service_completed_successfully"
    }
