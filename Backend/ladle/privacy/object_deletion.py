from datetime import datetime

from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session

from ladle.db.models import ObjectDeletionQueue


def queue_object_deletion(
    database: Session,
    object_key: str | None,
    *,
    reason: str,
    now: datetime,
) -> None:
    """Hand a private object to the deletion sweep rather than erasing it here.

    A request that deletes from the bucket inline and then fails to commit has
    already destroyed something the row still points at. Queuing keeps the two
    in one transaction: the sweep only ever sees keys whose owning row really
    was written. `object_key` is the primary key, so re-queuing the same object
    is a no-op rather than a conflict.

    `None` is the ordinary case — most accounts have nothing stored — and does
    nothing at all, which is what lets callers pass a nullable column straight
    in.
    """
    if object_key is None:
        return
    database.execute(
        insert(ObjectDeletionQueue)
        .values(
            object_key=object_key,
            reason=reason,
            available_at=now,
            created_at=now,
        )
        .on_conflict_do_nothing(index_elements=[ObjectDeletionQueue.object_key])
    )
