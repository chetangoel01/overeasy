import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import ExtractionCache, ImportJob, Recipe, SourceVideo
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


@pytest.mark.integration
def test_discover_returns_aggregated_public_source_data(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )
    recipe = json.loads(FIXTURE.read_text())
    source_url = "https://www.tiktok.com/@mia_cooks/video/1234567890"

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={
                    "installationID": f"discover-user-{index}",
                    "attestation": None,
                },
            ).json()
            for index in range(3)
        ]
        with Session(engine) as database, database.begin():
            source_id = uuid4()
            cache_id = uuid4()
            database.add(
                SourceVideo(
                    id=source_id,
                    platform="tiktok",
                    platform_video_id="1234567890",
                    canonical_url=source_url,
                    public_access_confirmed_at=datetime(2026, 8, 23, 12, tzinfo=UTC),
                    source_revision="1",
                    source_metadata={},
                )
            )
            database.flush()
            database.add(
                ExtractionCache(
                    id=cache_id,
                    source_video_id=source_id,
                    source_revision="1",
                    contract_version="v1",
                    prompt_version="recipe-test",
                    model_id="test-model",
                    template_json={
                        "title": "Lemon Orzo",
                        "description": recipe["description"],
                        "creatorName": "@mia_cooks",
                        "source": "tiktok",
                        "originalURL": source_url,
                        "servings": "4",
                        "ingredients": [],
                        "steps": [],
                        "notes": [],
                        "reviewStatus": "ready",
                        "uncertainties": [],
                    },
                    review_status="ready",
                    thumbnail_remote_url=recipe["images"][0]["remoteURL"],
                )
            )
            for index, user in enumerate(users[1:], start=1):
                recipe_id = uuid4()
                database.add(
                    Recipe(
                        id=recipe_id,
                        user_id=UUID(user["userID"]),
                        source_video_id=source_id,
                        source_cache_id=cache_id,
                        title=f"Private title edit {index}",
                        description=f"Private description edit {index}",
                        creator_name="Private creator edit",
                        source="tiktok",
                        original_url=source_url,
                        servings=Decimal(4),
                        favorite=False,
                        review_status="ready",
                        revision=1,
                        created_at=datetime(2026, 8, 23, 12, index, tzinfo=UTC),
                        updated_at=datetime(2026, 8, 23, 12, index, tzinfo=UTC),
                    )
                )

        response = client.get(
            "/v1/recipes/discover",
            headers={"Authorization": f"Bearer {users[0]['accessToken']}"},
        )

    assert response.status_code == 200
    payload = response.json()
    assert payload["items"] == [
        {
            "sourceID": str(source_id),
            "title": "Lemon Orzo",
            "description": recipe["description"],
            "creatorName": "@mia_cooks",
            "source": "tiktok",
            "originalURL": source_url,
            "imageURL": recipe["images"][0]["remoteURL"],
            "savedCount": 2,
            "savedRecipeID": None,
        }
    ]
    assert "userID" not in json.dumps(payload)
    assert "ingredients" not in payload["items"][0]

    with TestClient(app) as client:
        resumed = client.post(
            "/v1/auth/guest",
            json={"installationID": "discover-user-0", "attestation": None},
        ).json()
        save_headers = {"Authorization": f"Bearer {resumed['accessToken']}"}
        saved = client.post(
            f"/v1/recipes/discover/{source_id}/save",
            headers=save_headers,
        )
        repeated = client.post(
            f"/v1/recipes/discover/{source_id}/save",
            headers=save_headers,
        )
        refreshed = client.get(
            "/v1/recipes/discover",
            headers=save_headers,
        )
        sync = client.get(
            "/v1/recipes/sync?cursor=0&limit=10",
            headers=save_headers,
        )

    assert saved.status_code == 200
    assert saved.json()["title"] == "Lemon Orzo"
    assert saved.json()["reviewStatus"] == "ready"
    assert repeated.status_code == 200
    assert repeated.json()["id"] == saved.json()["id"]
    assert refreshed.status_code == 200
    assert refreshed.json()["items"][0]["savedRecipeID"] == saved.json()["id"]
    assert sync.status_code == 200
    assert sync.json()["changes"][-1]["recipe"]["id"] == saved.json()["id"]
    with Session(engine) as database:
        assert database.scalar(select(func.count()).select_from(ImportJob)) == 0
    engine.dispose()
