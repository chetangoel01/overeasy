from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.google import GoogleCredential
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import GoogleIdentity, User
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeGoogleCredentials:
    calls: list[str]

    def verify(self, identity_token: str) -> GoogleCredential:
        self.calls.append(identity_token)
        return GoogleCredential(subject="api-google-subject")


@pytest.mark.integration
def test_authenticated_guest_signs_in_with_google_and_keeps_its_library(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 26, 18, 0, tzinfo=UTC))
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
    credentials = FakeGoogleCredentials(calls=[])
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=sessions,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        google_credentials=credentials,
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "google-api-device", "attestation": None},
        ).json()
        response = client.post(
            "/v1/auth/google",
            json={
                "identityToken": "signed-google-id-token",
                "idempotencyKey": "google-api-attempt",
            },
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
        )

        assert response.status_code == 200
        signed_in = response.json()
        assert signed_in["userKind"] == "google"
        assert signed_in["userID"] == guest["userID"]
        assert signed_in["deviceID"] == guest["deviceID"]
        assert credentials.calls == ["signed-google-id-token"]

    with Session(engine) as database:
        identity = database.get(GoogleIdentity, "api-google-subject")
        assert identity is not None
        assert str(identity.user_id) == signed_in["userID"]

    with TestClient(app) as client:
        deleted = client.request(
            "DELETE",
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {signed_in['accessToken']}"},
            json={
                "confirmation": "DELETE",
                "refreshToken": signed_in["refreshToken"],
                "idempotencyKey": f"delete-{signed_in['userID']}",
            },
        )
        assert deleted.status_code == 204

    with Session(engine) as database:
        assert database.get(User, signed_in["userID"]) is None
        assert database.get(GoogleIdentity, "api-google-subject") is None

    engine.dispose()
