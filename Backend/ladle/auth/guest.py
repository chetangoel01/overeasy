from uuid import uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService, SessionTokens
from ladle.clock import Clock
from ladle.db.models import Device, User


def register_guest(
    database: Session,
    *,
    installation_id: str,
    assertion: str | None,
    attestation: AttestationService,
    sessions: SessionService,
    clock: Clock,
) -> SessionTokens:
    now = clock.now()
    attestation_state = attestation.verify(
        installation_id=installation_id,
        assertion=assertion,
    )
    device = database.execute(
        select(Device)
        .where(Device.installation_id == installation_id)
        .with_for_update()
    ).scalar_one_or_none()
    if device is None:
        user = User(id=uuid4(), kind="guest", created_at=now)
        database.add(user)
        database.flush()
        device = Device(
            id=uuid4(),
            user_id=user.id,
            installation_id=installation_id,
            attestation_state=attestation_state,
            created_at=now,
            last_seen_at=now,
        )
        database.add(device)
        database.flush()
    else:
        device.last_seen_at = now
        device.attestation_state = attestation_state

    return sessions.create(
        database,
        user_id=device.user_id,
        device_id=device.id,
    )
