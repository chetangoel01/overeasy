from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.apple import AppleCredential
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.cache.claims import ExtractionClaimService
from ladle.cache.service import ExtractionCacheService
from ladle.contracts.recipes import RecipeSource
from ladle.db.session import build_engine
from ladle.imports.orchestrator import ImportOrchestrator
from ladle.imports.reservations import ReservationService
from ladle.imports.source_identity import SourceIdentityParser
from ladle.imports.transitions import ImportTransitionService
from ladle.recipes.template_clone import RecipeTemplate, RecipeTemplateCloner
from tests.fakes.acquisition import FakeAcquirer
from tests.fakes.extraction import FakeExtractor
from tests.integration.recipes.test_recipe_service import manual_recipe
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class SynchronousWorker:
    orchestrator: ImportOrchestrator
    calls: list[UUID]

    def enqueue(self, job_id: UUID) -> None:
        self.calls.append(job_id)
        self.orchestrator.process(job_id)


@dataclass
class FakeAppleCredentials:
    subject: str

    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential:
        assert identity_token == "acceptance-identity"
        assert authorization_code == "acceptance-code"
        assert nonce == "acceptance-nonce"
        return AppleCredential(subject=self.subject)

    def revoke(self, refresh_token: str) -> None:
        del refresh_token


@pytest.mark.integration
def test_api_worker_shared_cache_apple_merge_and_tombstone_sync(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    reservations = ReservationService(
        clock=clock,
        lifetime=timedelta(hours=1),
    )
    cloner = RecipeTemplateCloner(
        clock=clock,
        reservations=reservations,
    )
    claims = ExtractionClaimService(
        clock=clock,
        lease_duration=timedelta(minutes=5),
    )
    cache = ExtractionCacheService(
        clock=clock,
        claims=claims,
        cloner=cloner,
        public_recheck_after=timedelta(days=7),
    )
    recipe = manual_recipe(uuid4()).model_copy(
        update={
            "source": RecipeSource.YOUTUBE,
            "original_url": "https://www.youtube.com/watch?v=acceptance-cache",
        }
    )
    acquirer = FakeAcquirer()
    extractor = FakeExtractor(RecipeTemplate.from_recipe(recipe))
    orchestrator = ImportOrchestrator(
        session_factory=sessions,
        cache=cache,
        acquirer=acquirer,
        extractor=extractor,
        clock=clock,
        transitions=ImportTransitionService(
            clock=clock,
            reservations=reservations,
        ),
    )
    worker = SynchronousWorker(orchestrator=orchestrator, calls=[])
    access_tokens = AccessTokenCodec(
        signing_secret="acceptance-signing-secret-that-is-long-enough",
        issuer="ladle-acceptance",
        lifetime=timedelta(minutes=15),
    )
    auth_sessions = SessionService(
        access_tokens=access_tokens,
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=30),
        rotation_grace=timedelta(seconds=5),
        clock=clock,
    )
    app = create_app(
        session_factory=sessions,
        clock=clock,
        session_service=auth_sessions,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        import_dispatcher=worker,
        source_parser=SourceIdentityParser(),
        apple_credentials=FakeAppleCredentials(subject="acceptance-apple-subject"),
    )

    with TestClient(app) as client:
        first = _guest(client, "acceptance-first")
        second = _guest(client, "acceptance-second")
        first_headers = _headers(first)
        second_headers = _headers(second)

        first_job = uuid4()
        first_submit = _submit(client, first_headers, first_job)
        assert first_submit.status_code == 202
        first_poll = client.get(
            f"/v1/imports/{first_job}",
            headers=first_headers,
        )
        assert first_poll.status_code == 200
        assert first_poll.json()["status"] == "ready"

        second_job = uuid4()
        second_submit = _submit(client, second_headers, second_job)
        assert second_submit.status_code == 202
        second_poll = client.get(
            f"/v1/imports/{second_job}",
            headers=second_headers,
        )
        assert second_poll.status_code == 200
        assert second_poll.json()["status"] == "ready"

        assert worker.calls == [first_job, second_job]
        assert len(acquirer.calls) == 1
        assert len(extractor.calls) == 1

        apple = client.post(
            "/v1/auth/apple",
            json={
                "identityToken": "acceptance-identity",
                "authorizationCode": "acceptance-code",
                "nonce": "acceptance-nonce",
                "idempotencyKey": "acceptance-apple-attempt",
            },
            headers=first_headers,
        )
        assert apple.status_code == 200
        assert apple.json()["userID"] == first["userID"]
        assert apple.json()["userKind"] == "apple"
        apple_headers = _headers(apple.json())

        initial_sync = client.get(
            "/v1/recipes/sync?cursor=0&limit=100",
            headers=apple_headers,
        )
        assert initial_sync.status_code == 200
        assert any(
            change["recipeID"] == first_poll.json()["recipeID"]
            for change in initial_sync.json()["changes"]
        )
        cursor = initial_sync.json()["nextCursor"]

        manual_id = uuid4()
        manual = manual_recipe(manual_id)
        created = client.put(
            f"/v1/recipes/{manual_id}",
            json={
                "baseRevision": 0,
                "recipe": manual.model_dump(mode="json", by_alias=True),
            },
            headers=apple_headers,
        )
        assert created.status_code == 200
        assert created.json()["revision"] == 1

        updated_recipe = manual.model_copy(update={"title": "Acceptance Edited Recipe"})
        updated = client.put(
            f"/v1/recipes/{manual_id}",
            json={
                "baseRevision": 1,
                "recipe": updated_recipe.model_dump(
                    mode="json",
                    by_alias=True,
                ),
            },
            headers=apple_headers,
        )
        assert updated.status_code == 200
        assert updated.json()["revision"] == 2

        deleted = client.delete(
            f"/v1/recipes/{manual_id}?baseRevision=2",
            headers=apple_headers,
        )
        assert deleted.status_code == 204

        delta = client.get(
            f"/v1/recipes/sync?cursor={cursor}&limit=100",
            headers=apple_headers,
        )
        assert delta.status_code == 200
        recipe_changes = [
            change
            for change in delta.json()["changes"]
            if change["recipeID"] == str(manual_id)
        ]
        assert recipe_changes
        assert [change["sequence"] for change in recipe_changes] == sorted(
            change["sequence"] for change in recipe_changes
        )
        assert recipe_changes[-1]["kind"] == "delete"
        assert recipe_changes[-1]["recipeRevision"] == 3
        assert recipe_changes[-1]["recipe"] is None

    engine.dispose()


def _guest(client: TestClient, installation_id: str) -> dict[str, object]:
    response = client.post(
        "/v1/auth/guest",
        json={"installationID": installation_id, "attestation": None},
    )
    assert response.status_code == 201
    return response.json()


def _headers(tokens: dict[str, object]) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['accessToken']}"}


def _submit(
    client: TestClient,
    headers: dict[str, str],
    job_id: UUID,
):
    return client.post(
        "/v1/imports",
        json={
            "jobID": str(job_id),
            "sourceURL": "https://youtu.be/acceptance-cache",
            "allowDuplicate": False,
            "idempotencyKey": str(job_id),
        },
        headers=headers,
    )
