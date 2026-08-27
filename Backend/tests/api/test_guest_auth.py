from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import (
    AccountDeletionAudit,
    Device,
    ImportJob,
    ObjectDeletionQueue,
    ProviderAttempt,
    Recipe,
    RecipeChange,
    RecipeImage,
    User,
    UserSyncState,
)
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.mark.integration
def test_guest_refresh_and_explicit_session_revocation(
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
    sessions = SessionService(
        access_tokens=access_tokens,
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=30),
        rotation_grace=timedelta(seconds=5),
        clock=clock,
    )
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=sessions,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "ios-installation-1",
                "attestation": None,
            },
        )
        assert guest.status_code == 201
        created = guest.json()
        assert created["refreshToken"]
        assert created["userKind"] == "guest"

        refreshed = client.post(
            "/v1/auth/refresh",
            json={
                "refreshToken": created["refreshToken"],
                "deviceID": created["deviceID"],
            },
        )
        assert refreshed.status_code == 200

        revoked = client.delete(
            "/v1/auth/session",
            headers={"Authorization": f"Bearer {refreshed.json()['accessToken']}"},
        )
        assert revoked.status_code == 204

        rejected_access = client.delete(
            "/v1/auth/session",
            headers={"Authorization": f"Bearer {refreshed.json()['accessToken']}"},
        )
        assert rejected_access.status_code == 401

        rejected = client.post(
            "/v1/auth/refresh",
            json={
                "refreshToken": refreshed.json()["refreshToken"],
                "deviceID": created["deviceID"],
            },
        )
        assert rejected.status_code == 401

        # A guest account has no credential other than its device binding, so
        # signing out must leave that binding intact.
        returning = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "ios-installation-1",
                "attestation": None,
            },
        )
        assert returning.status_code == 201
        assert returning.json()["userID"] == created["userID"]

    engine.dispose()


@pytest.mark.integration
def test_revoked_device_refresh_returns_unauthorized(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "revoked-refresh-installation",
                "attestation": None,
            },
        ).json()
        with Session(engine) as database, database.begin():
            device = database.get(Device, guest["deviceID"])
            assert device is not None
            device.attestation_state = "revoked"

        response = client.post(
            "/v1/auth/refresh",
            json={
                "refreshToken": guest["refreshToken"],
                "deviceID": guest["deviceID"],
            },
        )

    assert response.status_code == 401
    engine.dispose()


@pytest.mark.integration
def test_authenticated_guest_can_permanently_delete_account(
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

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "delete-account-installation",
                "attestation": None,
            },
        ).json()
        user_id = UUID(guest["userID"])
        recipe_id = uuid4()
        job_id = uuid4()
        with Session(engine) as database, database.begin():
            database.add(
                Recipe(
                    id=recipe_id,
                    user_id=user_id,
                    title="Delete me",
                    description="",
                    source="other",
                    original_url="https://manual.ladle.local/delete-me",
                    servings=Decimal(1),
                    favorite=False,
                    review_status="ready",
                    revision=1,
                    created_at=clock.now(),
                    updated_at=clock.now(),
                )
            )
            database.add(
                RecipeImage(
                    id=uuid4(),
                    recipe_id=recipe_id,
                    object_key="users/delete-me/image.jpg",
                    order_index=0,
                )
            )
            sync_state = database.get(UserSyncState, user_id)
            assert sync_state is not None
            sync_state.next_sequence = 2
            database.add(
                RecipeChange(
                    user_id=user_id,
                    sequence=1,
                    recipe_id=recipe_id,
                    kind="upsert",
                    recipe_revision=1,
                    changed_at=clock.now(),
                )
            )
            database.add(
                ImportJob(
                    id=job_id,
                    user_id=user_id,
                    source_url="https://youtu.be/delete-me",
                    source="youtube",
                    status="failed",
                    stage="failed",
                    failure_reason="parserUnavailable",
                    retry_count=0,
                    bypass_cache=False,
                    idempotency_key="delete-me",
                    created_at=clock.now(),
                    updated_at=clock.now(),
                    completed_at=clock.now(),
                )
            )
            database.add(
                ProviderAttempt(
                    id=uuid4(),
                    import_job_id=job_id,
                    provider="openrouter",
                    operation="extract",
                    idempotency_key="delete-me",
                    status="failed",
                    reserved_units=Decimal(0),
                    failure_code="test",
                    created_at=clock.now(),
                    completed_at=clock.now(),
                )
            )
        response = client.request(
            "DELETE",
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
            json={
                "confirmation": "DELETE",
                "refreshToken": guest["refreshToken"],
                "idempotencyKey": f"delete-{guest['userID']}",
            },
        )

        assert response.status_code == 204
        assert response.headers["X-Deletion-Status"] == "completed"
        assert response.headers["X-Deletion-ID"]
        repeated = client.request(
            "DELETE",
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
            json={
                "confirmation": "DELETE",
                "refreshToken": guest["refreshToken"],
                "idempotencyKey": f"delete-{guest['userID']}",
            },
        )
        assert repeated.status_code == 204
        assert repeated.headers["X-Deletion-ID"] == response.headers["X-Deletion-ID"]
        rejected = client.delete(
            "/v1/auth/session",
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
        )
        assert rejected.status_code == 401

    with Session(engine) as database:
        assert database.get(User, guest["userID"]) is None
        assert list(database.scalars(select(Device))) == []
        audit = database.scalar(select(AccountDeletionAudit))
        assert audit is not None
        assert audit.status == "completed"
        assert audit.account_kind == "guest"
        assert audit.user_digest != guest["userID"].encode()
        assert list(database.scalars(select(Recipe))) == []
        assert list(database.scalars(select(ImportJob))) == []
        assert list(database.scalars(select(ProviderAttempt))) == []
        assert list(database.scalars(select(RecipeChange))) == []
        cleanup = database.get(
            ObjectDeletionQueue,
            "users/delete-me/image.jpg",
        )
        assert cleanup is not None and cleanup.reason == "accountDeletion"

    engine.dispose()


@pytest.mark.integration
def test_account_deletion_requires_confirmation_and_current_refresh_token(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "delete-reauth", "attestation": None},
        ).json()
        headers = {"Authorization": f"Bearer {guest['accessToken']}"}
        missing_confirmation = client.request(
            "DELETE",
            "/v1/auth/account",
            headers=headers,
            json={
                "confirmation": "KEEP",
                "refreshToken": guest["refreshToken"],
                "idempotencyKey": "delete-reauth",
            },
        )
        wrong_refresh = client.request(
            "DELETE",
            "/v1/auth/account",
            headers=headers,
            json={
                "confirmation": "DELETE",
                "refreshToken": "wrong-refresh-token",
                "idempotencyKey": "delete-reauth",
            },
        )

    assert missing_confirmation.status_code == 422
    assert wrong_refresh.status_code == 401
    with Session(engine) as database:
        assert database.get(User, guest["userID"]) is not None
    engine.dispose()


@pytest.mark.integration
def test_attestation_enforcement_without_verifier_fails_closed(
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
        attestation=AttestationService(enforced=True, verifier=None),
    )

    with TestClient(app) as client:
        response = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "ios-installation-2",
                "attestation": None,
            },
        )

    assert response.status_code == 403
    engine.dispose()
