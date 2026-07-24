from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import ImportJob
from ladle.db.session import build_engine
from tests.integration.recipes.test_recipe_service import manual_recipe
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RecordingDispatcher:
    engine: object
    calls: list[UUID]

    def enqueue(self, job_id: UUID) -> None:
        with Session(self.engine) as database:
            assert database.get(ImportJob, job_id) is not None
        self.calls.append(job_id)


@pytest.mark.integration
def test_import_is_committed_before_dispatch_and_can_be_polled(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    dispatcher = RecordingDispatcher(engine=engine, calls=[])
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
        import_dispatcher=dispatcher,
    )
    job_id = uuid4()

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "import-api-test", "attestation": None},
        ).json()
        headers = {"Authorization": f"Bearer {guest['accessToken']}"}
        submitted = client.post(
            "/v1/imports",
            json={
                "jobID": str(job_id),
                "sourceURL": "https://youtu.be/api-import1",
                "allowDuplicate": False,
                "idempotencyKey": "api-import",
            },
            headers=headers,
        )
        assert submitted.status_code == 202
        assert submitted.json()["status"] == "parsing"
        assert dispatcher.calls == [job_id]

        polled = client.get(f"/v1/imports/{job_id}", headers=headers)
        assert polled.status_code == 200
        assert polled.json()["jobID"] == str(job_id)

        repeated = client.post(
            "/v1/imports",
            json={
                "jobID": str(uuid4()),
                "sourceURL": "https://youtu.be/api-import1",
                "allowDuplicate": False,
                "idempotencyKey": "api-import",
            },
            headers=headers,
        )
        assert repeated.status_code == 202
        assert repeated.json()["jobID"] == str(job_id)
        assert dispatcher.calls == [job_id]

    engine.dispose()


@pytest.mark.integration
def test_reimport_submission_attaches_to_current_recipe(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    dispatcher = RecordingDispatcher(engine=engine, calls=[])
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
        import_dispatcher=dispatcher,
    )
    recipe_id = uuid4()
    job_id = uuid4()

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "reimport-api-test", "attestation": None},
        ).json()
        headers = {"Authorization": f"Bearer {guest['accessToken']}"}
        created = client.put(
            f"/v1/recipes/{recipe_id}",
            json={
                "baseRevision": 0,
                "recipe": manual_recipe(recipe_id).model_dump(
                    mode="json",
                    by_alias=True,
                ),
            },
            headers=headers,
        )
        assert created.status_code == 200

        submitted = client.post(
            "/v1/imports",
            json={
                "jobID": str(job_id),
                "sourceURL": "https://youtu.be/reimport-api",
                "allowDuplicate": True,
                "idempotencyKey": str(job_id),
                "currentRecipeID": str(recipe_id),
                "correctionNotes": "Keep the lemon bright.",
            },
            headers=headers,
        )

    assert submitted.status_code == 202
    with Session(engine) as database:
        stored = database.get(ImportJob, job_id)
        assert stored is not None
        assert stored.current_recipe_id == recipe_id
        assert stored.base_recipe_revision == 1
        assert stored.bypass_cache is True
        assert stored.correction_notes_encrypted is not None
        assert b"Keep the lemon bright." not in stored.correction_notes_encrypted
    assert dispatcher.calls == [job_id]
    engine.dispose()
