from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

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
                "attestation": "unverified",
            },
        )

    assert response.status_code == 403
    engine.dispose()
