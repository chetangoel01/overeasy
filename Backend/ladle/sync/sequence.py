from uuid import UUID

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.db.models import UserSyncState


def allocate_sequence(session: Session, user_id: UUID) -> int:
    """Allocate under a row lock without committing the caller's transaction."""

    state = session.execute(
        select(UserSyncState).where(UserSyncState.user_id == user_id).with_for_update()
    ).scalar_one()
    sequence = state.next_sequence
    state.next_sequence += 1
    return sequence
