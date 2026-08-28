from uuid import UUID, uuid4

from sqlalchemy import select
from sqlalchemy.orm import Session

from ladle.auth.attestation import (
    AppAttestEvidence,
    AppAttestPurpose,
    AttestationService,
)
from ladle.auth.sessions import SessionService, SessionTokens
from ladle.clock import Clock
from ladle.db.models import Device, User, UserSyncState


def release_device_binding(database: Session, *, device_id: UUID) -> None:
    """Drop the installation-ID-to-account binding for a signed-out device.

    `register_guest` issues a session for whatever user the device row points
    at, so a device claimed by an Apple or Google identity would keep minting
    full sessions for that account after sign-out. A guest keeps its binding:
    the installation ID is the only credential a guest account ever has.
    """
    device = database.execute(
        select(Device).where(Device.id == device_id).with_for_update()
    ).scalar_one_or_none()
    if device is None:
        return
    user = database.get(User, device.user_id)
    if user is None or user.kind == "guest":
        return
    database.delete(device)


def register_guest(
    database: Session,
    *,
    installation_id: str,
    evidence: AppAttestEvidence | None,
    attestation: AttestationService,
    sessions: SessionService,
    clock: Clock,
) -> SessionTokens:
    now = clock.now()
    attestation_state = attestation.verify(
        database,
        installation_id=installation_id,
        purpose=AppAttestPurpose.GUEST_CREATION,
        method="POST",
        path="/v1/auth/guest",
        body_sha256=None,
        evidence=evidence,
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
        database.add(UserSyncState(user_id=user.id, next_sequence=1))
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
    attestation.bind_device(
        database,
        installation_id=installation_id,
        device_id=device.id,
        evidence=evidence,
    )

    return sessions.create(
        database,
        user_id=device.user_id,
        device_id=device.id,
    )
