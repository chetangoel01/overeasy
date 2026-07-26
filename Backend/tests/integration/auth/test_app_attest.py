import base64
import hashlib
import json
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import (
    AppAttestEvidence,
    AppAttestPurpose,
    AttestationRejected,
    AttestationService,
    IssuedAppAttestChallenge,
    VerifiedAppAttestation,
)
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import AppAttestKey
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


class FakeAppAttestVerifier:
    def verify_attestation(
        self,
        *,
        key_id: str,
        challenge: bytes,
        attestation_object: bytes,
    ) -> VerifiedAppAttestation:
        assert key_id == "test-key"
        assert challenge == b"server-challenge"
        assert attestation_object == b"apple-attestation"
        return VerifiedAppAttestation(
            public_key=b"public-key",
            receipt=b"receipt",
            environment="production",
        )

    def verify_assertion(
        self,
        *,
        public_key: bytes,
        client_data: bytes,
        assertion: bytes,
    ) -> int:
        assert public_key == b"public-key"
        assert assertion == b"apple-assertion"
        assert json.loads(client_data)["purpose"] == "importSubmission"
        return 1


@dataclass
class RecordingDispatcher:
    calls: list[UUID]

    def enqueue(self, job_id: UUID) -> None:
        self.calls.append(job_id)


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


@pytest.mark.integration
def test_attestation_challenge_is_single_use_and_assertion_binds_request(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 26, 15, 0, tzinfo=UTC))
    service = AttestationService(
        enforced=True,
        verifier=FakeAppAttestVerifier(),
        clock=clock,
        challenge_lifetime=timedelta(minutes=5),
        challenge_bytes=lambda: b"server-challenge",
    )

    with Session(engine) as database, database.begin():
        challenge = service.issue_challenge(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.GUEST_CREATION,
            key_id="test-key",
        )
        state = service.verify(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.GUEST_CREATION,
            method="POST",
            path="/v1/auth/guest",
            body_sha256=None,
            evidence=AppAttestEvidence(
                kind="attestation",
                key_id="test-key",
                challenge_id=challenge.id,
                challenge=challenge.challenge,
                attestation_object=_b64(b"apple-attestation"),
            ),
        )

    assert state == "verified"
    with Session(engine) as database:
        key = database.get(AppAttestKey, "test-key")
        assert key is not None
        assert key.installation_id == "installation-1"
        assert key.assertion_counter == 0

    body_hash = hashlib.sha256(b'{"jobID":"job-1"}').hexdigest()
    with Session(engine) as database, database.begin():
        assertion_challenge = service.issue_challenge(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.IMPORT_SUBMISSION,
            key_id="test-key",
        )
        client_data = service.client_data(
            challenge=assertion_challenge,
            installation_id="installation-1",
            purpose=AppAttestPurpose.IMPORT_SUBMISSION,
            method="POST",
            path="/v1/imports",
            body_sha256=body_hash,
        )
        assertion = AppAttestEvidence(
            kind="assertion",
            key_id="test-key",
            challenge_id=assertion_challenge.id,
            challenge=assertion_challenge.challenge,
            assertion=_b64(b"apple-assertion"),
            client_data=_b64(client_data),
        )
        assert (
            service.verify(
                database,
                installation_id="installation-1",
                purpose=AppAttestPurpose.IMPORT_SUBMISSION,
                method="POST",
                path="/v1/imports",
                body_sha256=body_hash,
                evidence=assertion,
            )
            == "verified"
        )

    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(AttestationRejected),
    ):
        service.verify(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.IMPORT_SUBMISSION,
            method="POST",
            path="/v1/imports",
            body_sha256=body_hash,
            evidence=assertion,
        )

    with Session(engine) as database:
        key = database.get(AppAttestKey, "test-key")
        assert key is not None
        assert key.assertion_counter == 1
    engine.dispose()


@pytest.mark.integration
def test_expired_challenge_and_revoked_installation_are_rejected(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 26, 15, 0, tzinfo=UTC))
    service = AttestationService(
        enforced=True,
        verifier=FakeAppAttestVerifier(),
        clock=clock,
        challenge_lifetime=timedelta(minutes=5),
        challenge_bytes=lambda: b"server-challenge",
    )
    with Session(engine) as database, database.begin():
        challenge = service.issue_challenge(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.GUEST_CREATION,
            key_id="test-key",
        )
    clock.value += timedelta(minutes=6)
    with (
        Session(engine) as database,
        database.begin(),
        pytest.raises(AttestationRejected),
    ):
        service.verify(
            database,
            installation_id="installation-1",
            purpose=AppAttestPurpose.GUEST_CREATION,
            method="POST",
            path="/v1/auth/guest",
            body_sha256=None,
            evidence=AppAttestEvidence(
                kind="attestation",
                key_id="test-key",
                challenge_id=challenge.id,
                challenge=challenge.challenge,
                attestation_object=_b64(b"apple-attestation"),
            ),
        )
    engine.dispose()


@pytest.mark.integration
def test_guest_and_import_endpoints_enforce_fresh_bound_app_attest_evidence(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 26, 15, 0, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    service = AttestationService(
        enforced=True,
        verifier=FakeAppAttestVerifier(),
        clock=clock,
        challenge_lifetime=timedelta(minutes=5),
        challenge_bytes=lambda: b"server-challenge",
    )
    dispatcher = RecordingDispatcher(calls=[])
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=SessionService(
            access_tokens=access_tokens,
            refresh_tokens=RefreshTokenCodec(),
            refresh_lifetime=timedelta(days=30),
            rotation_grace=timedelta(seconds=5),
            clock=clock,
        ),
        access_tokens=access_tokens,
        attestation=service,
        import_dispatcher=dispatcher,
    )

    with TestClient(app) as client:
        guest_challenge = client.post(
            "/v1/attestation/challenges",
            json={
                "installationID": "installation-1",
                "purpose": "guestCreation",
                "keyID": "test-key",
            },
        ).json()
        guest = client.post(
            "/v1/auth/guest",
            json={
                "installationID": "installation-1",
                "attestation": {
                    "kind": "attestation",
                    "keyID": "test-key",
                    "challengeID": guest_challenge["challengeID"],
                    "challenge": guest_challenge["challenge"],
                    "attestationObject": _b64(b"apple-attestation"),
                },
            },
        )
        assert guest.status_code == 201
        authorization = f"Bearer {guest.json()['accessToken']}"

        job_id = uuid4()
        body = json.dumps(
            {
                "allowDuplicate": False,
                "idempotencyKey": str(job_id),
                "jobID": str(job_id),
                "sourceURL": "https://youtu.be/attested-import",
            },
            separators=(",", ":"),
            sort_keys=True,
        ).encode()
        rejected = client.post(
            "/v1/imports",
            content=body,
            headers={
                "Authorization": authorization,
                "Content-Type": "application/json",
            },
        )
        assert rejected.status_code == 403
        assert dispatcher.calls == []

        assertion_challenge = client.post(
            "/v1/attestation/challenges",
            json={
                "installationID": "installation-1",
                "purpose": "importSubmission",
                "keyID": "test-key",
            },
        ).json()
        issued = IssuedAppAttestChallenge(
            id=UUID(assertion_challenge["challengeID"]),
            challenge=assertion_challenge["challenge"],
            expires_at=clock.now() + timedelta(minutes=5),
            requires_attestation=False,
        )
        client_data = service.client_data(
            challenge=issued,
            installation_id="installation-1",
            purpose=AppAttestPurpose.IMPORT_SUBMISSION,
            method="POST",
            path="/v1/imports",
            body_sha256=hashlib.sha256(body).hexdigest(),
        )
        accepted = client.post(
            "/v1/imports",
            content=body,
            headers={
                "Authorization": authorization,
                "Content-Type": "application/json",
                "X-App-Attest-Kind": "assertion",
                "X-App-Attest-Key-ID": "test-key",
                "X-App-Attest-Challenge-ID": assertion_challenge["challengeID"],
                "X-App-Attest-Challenge": assertion_challenge["challenge"],
                "X-App-Attest-Assertion": _b64(b"apple-assertion"),
                "X-App-Attest-Client-Data": _b64(client_data),
            },
        )

    assert accepted.status_code == 202
    assert dispatcher.calls == [job_id]
    engine.dispose()
