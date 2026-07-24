from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.auth.sessions import (
    RefreshTokenExpired,
    RefreshTokenReuseDetected,
    SessionService,
)
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import AuthSession, Device, User
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def service(clock: FrozenClock) -> SessionService:
    return SessionService(
        access_tokens=AccessTokenCodec(
            signing_secret="test-signing-secret-that-is-long-enough",
            issuer="ladle-test",
            lifetime=timedelta(minutes=15),
        ),
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=30),
        rotation_grace=timedelta(seconds=5),
        clock=clock,
    )


def seed_identity(session: Session, now: datetime) -> tuple[UUID, UUID]:
    user_id = uuid4()
    device_id = uuid4()
    session.add(User(id=user_id, kind="guest", created_at=now))
    session.flush()
    session.add(
        Device(
            id=device_id,
            user_id=user_id,
            installation_id=f"install-{device_id}",
            attestation_state="development",
            created_at=now,
            last_seen_at=now,
        )
    )
    session.flush()
    return user_id, device_id


@pytest.mark.integration
def test_concurrent_same_device_refresh_rotates_once_with_grace(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    auth = service(clock)

    with sessions.begin() as setup:
        user_id, device_id = seed_identity(setup, clock.now())
        initial = auth.create(setup, user_id=user_id, device_id=device_id)

    rendezvous = Barrier(3)

    def rotate() -> str | None:
        with sessions.begin() as database:
            rendezvous.wait()
            return auth.refresh(
                database,
                refresh_token=initial.refresh_token,
                device_id=device_id,
            ).refresh_token

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(rotate)
        second = executor.submit(rotate)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]

    assert sum(value is not None for value in results) == 1
    with sessions() as verification:
        stored = verification.scalar(select(AuthSession))
        assert stored is not None
        assert stored.revoked_at is None
        assert stored.previous_refresh_token_hash is not None

    engine.dispose()


@pytest.mark.integration
def test_confirmed_refresh_reuse_revokes_token_family(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    auth = service(clock)

    with Session(engine) as database, database.begin():
        user_id, device_id = seed_identity(database, clock.now())
        initial = auth.create(database, user_id=user_id, device_id=device_id)

    with Session(engine) as database, database.begin():
        auth.refresh(
            database,
            refresh_token=initial.refresh_token,
            device_id=device_id,
        )

    clock.value += timedelta(seconds=6)
    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(RefreshTokenReuseDetected),
    ):
        auth.refresh(
            database,
            refresh_token=initial.refresh_token,
            device_id=device_id,
        )

    with Session(engine) as verification:
        stored = verification.scalar(select(AuthSession))
        assert stored is not None
        assert stored.revoked_at == clock.now()

    engine.dispose()


@pytest.mark.integration
def test_expired_refresh_token_is_rejected(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    auth = service(clock)

    with Session(engine) as database, database.begin():
        user_id, device_id = seed_identity(database, clock.now())
        initial = auth.create(database, user_id=user_id, device_id=device_id)

    clock.value += timedelta(days=31)
    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(RefreshTokenExpired),
    ):
        auth.refresh(
            database,
            refresh_token=initial.refresh_token,
            device_id=device_id,
        )

    engine.dispose()
