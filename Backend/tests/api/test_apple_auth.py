from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.apple import AppleCredential
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import AppleIdentity, AuthSession, User
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeAppleCredentials:
    calls: list[tuple[str, str, str]]
    revocations: list[str] = field(default_factory=list)

    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential:
        self.calls.append((identity_token, authorization_code, nonce))
        return AppleCredential(
            subject="api-apple-subject",
            refresh_token="api-apple-refresh",
        )

    def revoke(self, refresh_token: str) -> None:
        self.revocations.append(refresh_token)


@pytest.mark.integration
def test_authenticated_guest_signs_in_with_apple_and_receives_rotated_tokens(
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
    credentials = FakeAppleCredentials(calls=[])
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=sessions,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        apple_credentials=credentials,
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "apple-api-device", "attestation": None},
        ).json()
        response = client.post(
            "/v1/auth/apple",
            json={
                "identityToken": "signed-identity-token",
                "authorizationCode": "one-time-code",
                "nonce": "raw-nonce",
                "idempotencyKey": "apple-api-attempt",
            },
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
        )

        assert response.status_code == 200
        signed_in = response.json()
        assert signed_in["userKind"] == "apple"
        assert signed_in["userID"] == guest["userID"]
        assert signed_in["deviceID"] == guest["deviceID"]
        assert signed_in["refreshToken"]
        assert credentials.calls == [
            ("signed-identity-token", "one-time-code", "raw-nonce")
        ]

        old_access = client.delete(
            "/v1/auth/session",
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
        )
        assert old_access.status_code == 401

    with Session(engine) as database:
        identity = database.get(AppleIdentity, "api-apple-subject")
        assert identity is not None
        active = list(
            database.scalars(
                select(AuthSession).where(AuthSession.revoked_at.is_(None))
            )
        )
        assert len(active) == 1
        assert active[0].user_id == identity.user_id

    with TestClient(app) as client:
        deleted = client.delete(
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {signed_in['accessToken']}"},
        )
        assert deleted.status_code == 204
        assert credentials.revocations == ["api-apple-refresh"]

    with Session(engine) as database:
        assert database.get(User, signed_in["userID"]) is None

    engine.dispose()
