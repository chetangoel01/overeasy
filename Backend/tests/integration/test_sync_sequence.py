from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from threading import Barrier, Event
from uuid import uuid4

import pytest
from sqlalchemy import create_engine, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.db.models import User, UserSyncState
from ladle.sync.sequence import allocate_sequence
from tests.integration.test_migrations import alembic_config


@pytest.mark.integration
def test_allocate_sequence_never_commits_its_transaction(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = create_engine(clean_postgres_url)
    user_id = uuid4()
    now = datetime.now(UTC)

    with Session(engine) as session:
        session.add(User(id=user_id, kind="guest", created_at=now))
        session.add(UserSyncState(user_id=user_id, next_sequence=1))
        session.commit()

        sequence = allocate_sequence(session, user_id)

        assert sequence == 1
        assert session.in_transaction()
        session.rollback()

    with Session(engine) as session:
        state = session.get(UserSyncState, user_id)
        assert state is not None
        assert state.next_sequence == 1

    engine.dispose()


@pytest.mark.integration
def test_later_sequence_waits_for_earlier_transaction_commit(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = create_engine(clean_postgres_url)
    sessions = sessionmaker(engine, expire_on_commit=False)
    user_id = uuid4()
    now = datetime.now(UTC)

    with sessions.begin() as setup:
        setup.add(User(id=user_id, kind="guest", created_at=now))
        setup.add(UserSyncState(user_id=user_id, next_sequence=1))

    first = sessions()
    first.begin()
    assert allocate_sequence(first, user_id) == 1

    rendezvous = Barrier(2)
    second_allocated = Event()

    def allocate_second() -> int:
        with sessions.begin() as second:
            rendezvous.wait()
            sequence = allocate_sequence(second, user_id)
            second_allocated.set()
            return sequence

    with ThreadPoolExecutor(max_workers=1) as executor:
        future = executor.submit(allocate_second)
        rendezvous.wait()

        assert not second_allocated.wait(timeout=0.25)
        first.commit()

        assert second_allocated.wait(timeout=5)
        assert future.result(timeout=5) == 2

    with sessions() as verification:
        assert (
            verification.scalar(
                select(UserSyncState.next_sequence).where(
                    UserSyncState.user_id == user_id
                )
            )
            == 3
        )

    first.close()
    engine.dispose()
