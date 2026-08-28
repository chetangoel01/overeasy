from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from pydantic import SecretStr
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.auth.apple import AppleCredential
from ladle.auth.deletion import AccountDeletionService, AccountDeletionUnavailable
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.crypto.private_text import VersionedPrivateTextCipher
from ladle.db.models import AccountDeletionAudit, AppleIdentity, Device, User
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config

KEY_ID = "2026-q3"


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RecordingAppleCredentials:
    revoked: list[str] = field(default_factory=list)

    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential:
        raise NotImplementedError

    def revoke(self, refresh_token: str) -> None:
        self.revoked.append(refresh_token)


def cipher(secret: str, *, key_id: str = KEY_ID) -> VersionedPrivateTextCipher:
    return VersionedPrivateTextCipher(
        active_key_id=key_id,
        keys={key_id: SecretStr(secret)},
    )


def seed_apple_user(
    database: Session,
    now: datetime,
    encrypted: bytes,
) -> tuple[UUID, UUID]:
    user_id = uuid4()
    device_id = uuid4()
    database.add(User(id=user_id, kind="apple", created_at=now))
    database.flush()
    database.add(
        Device(
            id=device_id,
            user_id=user_id,
            installation_id=f"install-{device_id}",
            attestation_state="development",
            created_at=now,
            last_seen_at=now,
        )
    )
    database.add(
        AppleIdentity(
            apple_sub=f"apple-{user_id}",
            user_id=user_id,
            refresh_token_encrypted=encrypted,
            created_at=now,
        )
    )
    database.flush()
    return user_id, device_id


def delete_with_service_cipher(
    clean_postgres_url: str,
    service_cipher: VersionedPrivateTextCipher,
) -> tuple[AccountDeletionAudit, RecordingAppleCredentials]:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions_factory = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 8, 27, 12, 0, tzinfo=UTC))
    codec = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    auth = SessionService(
        access_tokens=codec,
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=30),
        rotation_grace=timedelta(seconds=5),
        clock=clock,
    )

    encrypted = cipher("apple-secret-before-rotation-32ch").encrypt("apple-grant")
    with sessions_factory.begin() as setup:
        user_id, device_id = seed_apple_user(setup, clock.now(), encrypted)
        tokens = auth.create(setup, user_id=user_id, device_id=device_id)

    apple = RecordingAppleCredentials()
    service = AccountDeletionService(
        session_factory=sessions_factory,
        sessions=auth,
        clock=clock,
        audit_secret="deletion-audit-secret",
        private_text=service_cipher,
        apple_credentials=apple,
    )

    claims = codec.decode(tokens.access_token, now=clock.now())
    assert tokens.refresh_token is not None
    with pytest.raises(AccountDeletionUnavailable):
        service.delete(
            claims=claims,
            refresh_token=tokens.refresh_token,
            idempotency_key="delete-once",
        )

    with Session(engine) as database:
        audit = database.execute(select(AccountDeletionAudit)).scalar_one()
    engine.dispose()
    return audit, apple


@pytest.mark.integration
def test_a_failed_tag_check_marks_the_deletion_failed_instead_of_crashing(
    clean_postgres_url: str,
) -> None:
    """Same keyring id, different secret — the AEAD tag check fails.

    An operator rotating a keyring secret in place (or a restore into an
    environment whose keyring maps the id to different material) makes every
    stored Apple refresh token raise cryptography's InvalidTag, which is not
    a ValueError. That must degrade exactly like the other revocation
    failures: AccountDeletionUnavailable (the route's 503), audit at
    'failed' with the failure class recorded — not an unhandled 500 with the
    audit wedged at 'revokingProvider' forever.
    """
    audit, apple = delete_with_service_cipher(
        clean_postgres_url,
        cipher("apple-secret-after-rotation-32chr"),
    )

    assert audit.status == "failed"
    assert audit.failure_code == "InvalidTag"
    assert apple.revoked == []


@pytest.mark.integration
def test_a_missing_keyring_id_degrades_the_same_way(
    clean_postgres_url: str,
) -> None:
    """The neighbouring failure: the envelope's key id is absent entirely.

    This is the ValueError path the except clause already caught; it pins
    the contrast so the two decrypt failures stay behaviourally identical.
    """
    audit, apple = delete_with_service_cipher(
        clean_postgres_url,
        cipher("apple-secret-after-rotation-32chr", key_id="2026-q4"),
    )

    assert audit.status == "failed"
    assert audit.failure_code == "ValueError"
    assert apple.revoked == []
