from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.apple import AppleCredential, AppleTokenRevocationFailed
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import (
    AccountDeletionAudit,
    AppleIdentity,
    AuthSession,
    Device,
    User,
)
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
        assert credentials.revocations == ["api-apple-refresh"]

    with Session(engine) as database:
        assert database.get(User, signed_in["userID"]) is None

    engine.dispose()


@pytest.mark.integration
def test_signing_out_of_an_apple_account_releases_the_device_binding(
    clean_postgres_url: str,
) -> None:
    """Sign-out must not leave the installation ID minting Apple sessions.

    `register_guest` looks a device up by installation ID and issues a session
    for whatever user that row points at. Once a guest has been claimed by an
    Apple identity, an unauthenticated guest registration replaying the same
    installation ID would otherwise hand out a full Apple session.
    """
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
        apple_credentials=FakeAppleCredentials(calls=[]),
    )

    with TestClient(app) as client:
        guest = client.post(
            "/v1/auth/guest",
            json={"installationID": "handed-over-device", "attestation": None},
        ).json()
        signed_in = client.post(
            "/v1/auth/apple",
            json={
                "identityToken": "signed-identity-token",
                "authorizationCode": "one-time-code",
                "nonce": "raw-nonce",
                "idempotencyKey": "handover-attempt",
            },
            headers={"Authorization": f"Bearer {guest['accessToken']}"},
        ).json()
        assert signed_in["userKind"] == "apple"

        signed_out = client.delete(
            "/v1/auth/session",
            headers={"Authorization": f"Bearer {signed_in['accessToken']}"},
        )
        assert signed_out.status_code == 204

        replayed = client.post(
            "/v1/auth/guest",
            json={"installationID": "handed-over-device", "attestation": None},
        )

        assert replayed.status_code == 201
        inherited = replayed.json()
        assert inherited["userKind"] == "guest"
        assert inherited["userID"] != signed_in["userID"]

    with Session(engine) as database:
        device = database.scalars(
            select(Device).where(Device.installation_id == "handed-over-device")
        ).one()
        assert str(device.user_id) == inherited["userID"]
        assert database.get(User, signed_in["userID"]) is not None

    engine.dispose()


@dataclass
class ConfigurableAppleCredentials:
    """FakeAppleCredentials with a controllable token and failing revocation."""

    refresh_token: str | None
    revocations: list[str] = field(default_factory=list)
    revoke_failures: int = 0

    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential:
        del identity_token, authorization_code, nonce
        return AppleCredential(
            subject="configurable-apple-subject",
            refresh_token=self.refresh_token,
        )

    def revoke(self, refresh_token: str) -> None:
        if self.revoke_failures > 0:
            self.revoke_failures -= 1
            raise AppleTokenRevocationFailed("apple rejected the revocation")
        self.revocations.append(refresh_token)


def apple_deletion_app(
    engine: object,
    credentials: ConfigurableAppleCredentials,
) -> tuple[object, object]:
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),  # type: ignore[arg-type]
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
        apple_credentials=credentials,
    )
    return app, clock


def sign_in_with_apple(client: TestClient, installation_id: str) -> dict[str, str]:
    guest = client.post(
        "/v1/auth/guest",
        json={"installationID": installation_id, "attestation": None},
    ).json()
    signed_in = client.post(
        "/v1/auth/apple",
        json={
            "identityToken": "signed-identity-token",
            "authorizationCode": "one-time-code",
            "nonce": "raw-nonce",
            "idempotencyKey": f"sign-in-{installation_id}",
        },
        headers={"Authorization": f"Bearer {guest['accessToken']}"},
    ).json()
    assert signed_in["userKind"] == "apple"
    return signed_in


@pytest.mark.integration
def test_deleting_an_account_whose_identity_has_no_refresh_token_skips_revocation(
    clean_postgres_url: str,
) -> None:
    """Apple sometimes returns no refresh token on the code exchange: the
    stored identity then has nothing to revoke, and deletion must complete
    without calling Apple rather than failing or inventing a call."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    credentials = ConfigurableAppleCredentials(refresh_token=None)
    app, _ = apple_deletion_app(engine, credentials)

    with TestClient(app) as client:
        signed_in = sign_in_with_apple(client, "tokenless-device")
        deleted = client.request(
            "DELETE",
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {signed_in['accessToken']}"},
            json={
                "confirmation": "DELETE",
                "refreshToken": signed_in["refreshToken"],
                "idempotencyKey": "delete-tokenless",
            },
        )
        assert deleted.status_code == 204
        assert deleted.headers["X-Deletion-Status"] == "completed"
        assert credentials.revocations == []

    with Session(engine) as database:
        assert database.get(User, signed_in["userID"]) is None

    engine.dispose()


@pytest.mark.integration
def test_failed_apple_revocation_blocks_deletion_until_a_retry_succeeds(
    clean_postgres_url: str,
) -> None:
    """When Apple rejects the revocation (an expired or already-revoked
    grant), the account must NOT be deleted — the token would be lost with
    the grant possibly still live. The same idempotency key must be able to
    retry to completion once Apple accepts."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    credentials = ConfigurableAppleCredentials(
        refresh_token="sticky-refresh-token",
        revoke_failures=1,
    )
    app, _ = apple_deletion_app(engine, credentials)

    with TestClient(app) as client:
        signed_in = sign_in_with_apple(client, "sticky-device")
        body = {
            "confirmation": "DELETE",
            "refreshToken": signed_in["refreshToken"],
            "idempotencyKey": "delete-sticky",
        }
        headers = {"Authorization": f"Bearer {signed_in['accessToken']}"}

        refused = client.request(
            "DELETE", "/v1/auth/account", headers=headers, json=body
        )
        assert refused.status_code == 503
        assert credentials.revocations == []
        with Session(engine) as database:
            assert database.get(User, signed_in["userID"]) is not None
            audit = database.scalars(select(AccountDeletionAudit)).one()
            assert audit.status == "failed"
            assert audit.failure_code == "AppleTokenRevocationFailed"

        retried = client.request(
            "DELETE", "/v1/auth/account", headers=headers, json=body
        )
        assert retried.status_code == 204
        assert retried.headers["X-Deletion-Status"] == "completed"
        assert credentials.revocations == ["sticky-refresh-token"]

    with Session(engine) as database:
        assert database.get(User, signed_in["userID"]) is None

    engine.dispose()
