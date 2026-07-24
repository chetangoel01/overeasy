import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[3] / "Contracts" / "Fixtures" / "recipe-ready.json"


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.mark.integration
def test_recipe_crud_conflict_and_sync_tombstone(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=SessionService(
            access_tokens=access_tokens,
            refresh_tokens=RefreshTokenCodec(),
            refresh_lifetime=timedelta(days=30),
            rotation_grace=timedelta(seconds=5),
            clock=clock,
        ),
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
    )
    recipe_id = uuid4()
    recipe = json.loads(FIXTURE.read_text())
    recipe.update(
        {
            "id": str(recipe_id),
            "source": "other",
            "originalURL": f"https://manual.ladle.local/{recipe_id}",
        }
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "recipe-api-test", "attestation": None},
        ).json()
        headers = {"Authorization": f"Bearer {guest['accessToken']}"}

        created = client.put(
            f"/v1/recipes/{recipe_id}",
            json={"baseRevision": 0, "recipe": recipe},
            headers=headers,
        )
        assert created.status_code == 200
        assert created.json()["revision"] == 1

        recipe["title"] = "Edited through API"
        updated = client.put(
            f"/v1/recipes/{recipe_id}",
            json={"baseRevision": 1, "recipe": recipe},
            headers=headers,
        )
        assert updated.status_code == 200
        assert updated.json()["revision"] == 2

        stale = client.put(
            f"/v1/recipes/{recipe_id}",
            json={"baseRevision": 1, "recipe": recipe},
            headers=headers,
        )
        assert stale.status_code == 409
        assert stale.json()["error"]["code"] == "syncConflict"
        assert stale.json()["error"]["details"]["currentRevision"] == 2

        deleted = client.delete(
            f"/v1/recipes/{recipe_id}?baseRevision=2",
            headers=headers,
        )
        assert deleted.status_code == 204

        page = client.get("/v1/recipes/sync?cursor=0&limit=10", headers=headers)
        assert page.status_code == 200
        assert page.json()["changes"][-1]["kind"] == "delete"
        assert page.json()["nextCursor"] == 3

    engine.dispose()
