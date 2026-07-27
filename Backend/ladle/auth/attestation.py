import base64
import hashlib
import hmac
import json
import secrets
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from itertools import pairwise
from typing import Literal, Protocol
from uuid import UUID, uuid4

import cbor2
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from pydantic import Field, model_validator
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ladle.clock import Clock, SystemClock
from ladle.contracts.common import WireModel, WireUUID
from ladle.db.models import AppAttestChallenge, AppAttestKey, Device

_APPLE_NONCE_OID = x509.ObjectIdentifier("1.2.840.113635.100.8.2")
_DEVELOPMENT_AAGUID = b"appattestdevelop"
_PRODUCTION_AAGUID = b"appattest" + (b"\0" * 7)
_MAX_ATTESTATION_BYTES = 128 * 1024
_MAX_ASSERTION_BYTES = 16 * 1024
_MAX_CLIENT_DATA_BYTES = 8 * 1024

# Apple App Attestation Root CA, published by Apple at:
# https://www.apple.com/certificateauthority/Apple_App_Attestation_Root_CA.pem
_APPLE_APP_ATTEST_ROOT = b"""-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
"""


class AttestationRejected(Exception):
    pass


class AppAttestPurpose(StrEnum):
    GUEST_CREATION = "guestCreation"
    IMPORT_SUBMISSION = "importSubmission"
    IMPORT_RETRY = "importRetry"


class AppAttestEvidence(WireModel):
    kind: Literal["attestation", "assertion"]
    key_id: str = Field(min_length=1, max_length=255)
    challenge_id: WireUUID
    challenge: str = Field(min_length=1, max_length=512)
    attestation_object: str | None = Field(default=None, max_length=180_000)
    assertion: str | None = Field(default=None, max_length=24_000)
    client_data: str | None = Field(default=None, max_length=12_000)

    @model_validator(mode="after")
    def validate_kind_payload(self) -> "AppAttestEvidence":
        if self.kind == "attestation":
            if self.attestation_object is None:
                raise ValueError("attestation evidence requires an object")
            if self.assertion is not None or self.client_data is not None:
                raise ValueError("attestation evidence cannot include an assertion")
        elif (
            self.assertion is None
            or self.client_data is None
            or self.attestation_object is not None
        ):
            raise ValueError("assertion evidence is malformed")
        return self


@dataclass(frozen=True)
class VerifiedAppAttestation:
    public_key: bytes
    receipt: bytes
    environment: Literal["development", "production"]


class AppAttestVerifier(Protocol):
    def verify_attestation(
        self,
        *,
        key_id: str,
        challenge: bytes,
        attestation_object: bytes,
    ) -> VerifiedAppAttestation: ...

    def verify_assertion(
        self,
        *,
        public_key: bytes,
        client_data: bytes,
        assertion: bytes,
    ) -> int: ...


@dataclass(frozen=True)
class IssuedAppAttestChallenge:
    id: UUID
    challenge: str
    expires_at: datetime
    requires_attestation: bool


class AppleAppAttestVerifier:
    """Apple App Attest attestation and assertion verifier.

    The checks follow Apple's server validation sequence: a pinned App Attest
    certificate chain, nonce extension, App ID hash, key identifier, AAGUID,
    credential ID, assertion signature, and monotonic counter.
    """

    def __init__(
        self,
        *,
        app_id: str,
        environment: Literal["development", "production"],
        clock: Clock | None = None,
        trusted_root_pem: bytes = _APPLE_APP_ATTEST_ROOT,
    ) -> None:
        self._app_id_hash = hashlib.sha256(app_id.encode("utf-8")).digest()
        self._environment = environment
        self._clock = clock or SystemClock()
        self._root = x509.load_pem_x509_certificate(trusted_root_pem)

    def verify_attestation(
        self,
        *,
        key_id: str,
        challenge: bytes,
        attestation_object: bytes,
    ) -> VerifiedAppAttestation:
        if not attestation_object or len(attestation_object) > _MAX_ATTESTATION_BYTES:
            raise AttestationRejected("attestation object size is invalid")
        decoded = _decode_cbor_mapping(attestation_object)
        if decoded.get("fmt") != "apple-appattest":
            raise AttestationRejected("attestation format is invalid")
        statement = decoded.get("attStmt")
        auth_data = decoded.get("authData")
        if not isinstance(statement, dict) or not isinstance(auth_data, bytes):
            raise AttestationRejected("attestation structure is invalid")
        chain_value = statement.get("x5c")
        receipt = statement.get("receipt")
        if (
            not isinstance(chain_value, list)
            or not 2 <= len(chain_value) <= 4
            or not all(isinstance(value, bytes) for value in chain_value)
            or not isinstance(receipt, bytes)
            or not receipt
        ):
            raise AttestationRejected("attestation statement is invalid")

        certificates = _load_certificates(chain_value)
        self._verify_certificate_chain(certificates)
        leaf = certificates[0]
        public_key = leaf.public_key()
        if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(
            public_key.curve, ec.SECP256R1
        ):
            raise AttestationRejected("attested key is not P-256")

        expected_key_id = _decode_base64(key_id, maximum=64)
        uncompressed = public_key.public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
        if not hmac.compare_digest(
            hashlib.sha256(uncompressed).digest(), expected_key_id
        ):
            raise AttestationRejected("key identifier does not match certificate")

        rp_id_hash, counter, aaguid, credential_id = _attested_auth_data(auth_data)
        if not hmac.compare_digest(rp_id_hash, self._app_id_hash):
            raise AttestationRejected("App ID hash is invalid")
        if counter != 0:
            raise AttestationRejected("attestation counter is not zero")
        expected_aaguid = (
            _DEVELOPMENT_AAGUID
            if self._environment == "development"
            else _PRODUCTION_AAGUID
        )
        if not hmac.compare_digest(aaguid, expected_aaguid):
            raise AttestationRejected("App Attest environment is invalid")
        if not hmac.compare_digest(credential_id, expected_key_id):
            raise AttestationRejected("credential identifier is invalid")

        client_data_hash = hashlib.sha256(challenge).digest()
        nonce = hashlib.sha256(auth_data + client_data_hash).digest()
        try:
            extension = leaf.extensions.get_extension_for_oid(_APPLE_NONCE_OID)
        except x509.ExtensionNotFound as error:
            raise AttestationRejected("attestation nonce is missing") from error
        extension_value = extension.value
        if not isinstance(extension_value, x509.UnrecognizedExtension):
            raise AttestationRejected("attestation nonce extension is invalid")
        candidates = tuple(_der_octet_strings(extension_value.value))
        if len(candidates) != 1 or not hmac.compare_digest(candidates[0], nonce):
            raise AttestationRejected("attestation nonce is invalid")

        return VerifiedAppAttestation(
            public_key=public_key.public_bytes(
                serialization.Encoding.DER,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ),
            receipt=receipt,
            environment=self._environment,
        )

    def verify_assertion(
        self,
        *,
        public_key: bytes,
        client_data: bytes,
        assertion: bytes,
    ) -> int:
        if not assertion or len(assertion) > _MAX_ASSERTION_BYTES:
            raise AttestationRejected("assertion size is invalid")
        if not client_data or len(client_data) > _MAX_CLIENT_DATA_BYTES:
            raise AttestationRejected("client data size is invalid")
        decoded = _decode_cbor_mapping(assertion)
        signature = decoded.get("signature")
        auth_data = decoded.get("authenticatorData")
        if (
            not isinstance(signature, bytes)
            or not signature
            or not isinstance(auth_data, bytes)
            or len(auth_data) < 37
        ):
            raise AttestationRejected("assertion structure is invalid")
        if not hmac.compare_digest(auth_data[:32], self._app_id_hash):
            raise AttestationRejected("assertion App ID hash is invalid")
        try:
            key = serialization.load_der_public_key(public_key)
        except ValueError as error:
            raise AttestationRejected("stored App Attest key is invalid") from error
        if not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(
            key.curve, ec.SECP256R1
        ):
            raise AttestationRejected("stored App Attest key is not P-256")
        signed_data = auth_data + hashlib.sha256(client_data).digest()
        try:
            key.verify(signature, signed_data, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature as error:
            raise AttestationRejected("assertion signature is invalid") from error
        return int.from_bytes(auth_data[33:37], "big")

    def _verify_certificate_chain(
        self,
        certificates: list[x509.Certificate],
    ) -> None:
        now = self._clock.now()
        root_fingerprint = self._root.fingerprint(hashes.SHA256())
        if certificates[-1].fingerprint(hashes.SHA256()) == root_fingerprint:
            chain = certificates
        else:
            chain = [*certificates, self._root]
        if chain[-1].fingerprint(hashes.SHA256()) != root_fingerprint:
            raise AttestationRejected("certificate chain has an untrusted root")
        for certificate in chain:
            if (
                now < certificate.not_valid_before_utc
                or now > certificate.not_valid_after_utc
            ):
                raise AttestationRejected("certificate is outside its validity window")
        for index, (certificate, issuer) in enumerate(pairwise(chain)):
            if certificate.issuer != issuer.subject:
                raise AttestationRejected("certificate issuer does not match")
            if index > 0:
                try:
                    constraints = certificate.extensions.get_extension_for_class(
                        x509.BasicConstraints
                    ).value
                except x509.ExtensionNotFound as error:
                    raise AttestationRejected(
                        "intermediate certificate lacks CA constraints"
                    ) from error
                if not constraints.ca:
                    raise AttestationRejected("intermediate certificate is not a CA")
            _verify_certificate_signature(certificate, issuer)


class AttestationService:
    def __init__(
        self,
        *,
        enforced: bool,
        verifier: AppAttestVerifier | None = None,
        clock: Clock | None = None,
        challenge_lifetime: timedelta = timedelta(minutes=5),
        challenge_bytes: Callable[[], bytes] | None = None,
    ) -> None:
        self._enforced = enforced
        self._verifier = verifier
        self._clock = clock or SystemClock()
        self._challenge_lifetime = challenge_lifetime
        self._challenge_bytes = challenge_bytes or (lambda: secrets.token_bytes(32))

    @property
    def configured(self) -> bool:
        return self._verifier is not None

    @property
    def enforced(self) -> bool:
        return self._enforced

    def issue_challenge(
        self,
        database: Session,
        *,
        installation_id: str,
        purpose: AppAttestPurpose,
        key_id: str | None,
    ) -> IssuedAppAttestChallenge:
        raw = self._challenge_bytes()
        if not 16 <= len(raw) <= 64:
            raise RuntimeError("App Attest challenge source returned an unsafe length")
        now = self._clock.now()
        identifier = uuid4()
        expires_at = now + self._challenge_lifetime
        active_key = None
        if key_id:
            active_key = database.scalar(
                select(AppAttestKey.key_id).where(
                    AppAttestKey.key_id == key_id,
                    AppAttestKey.installation_id == installation_id,
                    AppAttestKey.status == "valid",
                )
            )
        database.add(
            AppAttestChallenge(
                id=identifier,
                installation_id=installation_id,
                purpose=purpose.value,
                challenge_hash=hashlib.sha256(raw).digest(),
                created_at=now,
                expires_at=expires_at,
            )
        )
        return IssuedAppAttestChallenge(
            id=identifier,
            challenge=base64.b64encode(raw).decode("ascii"),
            expires_at=expires_at,
            requires_attestation=active_key is None,
        )

    def client_data(
        self,
        *,
        challenge: IssuedAppAttestChallenge,
        installation_id: str,
        purpose: AppAttestPurpose,
        method: str,
        path: str,
        body_sha256: str | None,
    ) -> bytes:
        return json.dumps(
            {
                "bodySHA256": body_sha256,
                "challenge": challenge.challenge,
                "challengeID": str(challenge.id),
                "installationID": installation_id,
                "method": method.upper(),
                "path": path,
                "purpose": purpose.value,
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")

    def verify(
        self,
        database: Session,
        *,
        installation_id: str,
        purpose: AppAttestPurpose,
        method: str,
        path: str,
        body_sha256: str | None,
        evidence: AppAttestEvidence | None,
    ) -> str:
        if not self._enforced:
            return "development"
        if self._verifier is None or evidence is None:
            raise AttestationRejected("App Attest evidence is required")
        device_state = database.execute(
            select(Device.attestation_state)
            .where(Device.installation_id == installation_id)
            .with_for_update()
        ).scalar_one_or_none()
        if device_state == "revoked":
            raise AttestationRejected("App Attest installation is revoked")
        challenge = database.execute(
            select(AppAttestChallenge)
            .where(AppAttestChallenge.id == evidence.challenge_id)
            .with_for_update()
        ).scalar_one_or_none()
        now = self._clock.now()
        raw_challenge = _decode_base64(evidence.challenge, maximum=64)
        if (
            challenge is None
            or challenge.consumed_at is not None
            or challenge.expires_at <= now
            or challenge.installation_id != installation_id
            or challenge.purpose != purpose.value
            or not hmac.compare_digest(
                challenge.challenge_hash,
                hashlib.sha256(raw_challenge).digest(),
            )
        ):
            raise AttestationRejected("App Attest challenge is invalid")
        challenge.consumed_at = now

        if evidence.kind == "attestation":
            if purpose != AppAttestPurpose.GUEST_CREATION:
                raise AttestationRejected(
                    "new attestations are limited to guest creation"
                )
            assert evidence.attestation_object is not None
            verified = self._verifier.verify_attestation(
                key_id=evidence.key_id,
                challenge=raw_challenge,
                attestation_object=_decode_base64(
                    evidence.attestation_object,
                    maximum=_MAX_ATTESTATION_BYTES,
                ),
            )
            existing = database.execute(
                select(AppAttestKey)
                .where(AppAttestKey.key_id == evidence.key_id)
                .with_for_update()
            ).scalar_one_or_none()
            if existing is not None:
                raise AttestationRejected("App Attest key is already registered")
            database.add(
                AppAttestKey(
                    key_id=evidence.key_id,
                    installation_id=installation_id,
                    public_key=verified.public_key,
                    receipt=verified.receipt,
                    environment=verified.environment,
                    assertion_counter=0,
                    status="valid",
                    created_at=now,
                )
            )
            database.flush()
            return "verified"

        key = database.execute(
            select(AppAttestKey)
            .where(AppAttestKey.key_id == evidence.key_id)
            .with_for_update()
        ).scalar_one_or_none()
        if (
            key is None
            or key.installation_id != installation_id
            or key.status != "valid"
        ):
            raise AttestationRejected("App Attest key is unavailable")
        assert evidence.client_data is not None
        assert evidence.assertion is not None
        client_data = _decode_base64(
            evidence.client_data,
            maximum=_MAX_CLIENT_DATA_BYTES,
        )
        self._validate_client_data(
            client_data,
            challenge=evidence.challenge,
            challenge_id=evidence.challenge_id,
            installation_id=installation_id,
            purpose=purpose,
            method=method,
            path=path,
            body_sha256=body_sha256,
        )
        try:
            counter = self._verifier.verify_assertion(
                public_key=key.public_key,
                client_data=client_data,
                assertion=_decode_base64(
                    evidence.assertion,
                    maximum=_MAX_ASSERTION_BYTES,
                ),
            )
        except AttestationRejected:
            self._revoke_key(database, key, reason="invalidAssertion")
            raise
        if counter <= key.assertion_counter:
            self._revoke_key(database, key, reason="assertionReplay")
            raise AttestationRejected("assertion counter did not increase")
        key.assertion_counter = counter
        key.last_asserted_at = now
        return "verified"

    def bind_device(
        self,
        database: Session,
        *,
        installation_id: str,
        device_id: UUID,
        evidence: AppAttestEvidence | None,
    ) -> None:
        if not self._enforced or evidence is None:
            return
        device = database.execute(
            select(Device)
            .where(
                Device.id == device_id,
                Device.installation_id == installation_id,
            )
            .with_for_update()
        ).scalar_one_or_none()
        key = database.execute(
            select(AppAttestKey)
            .where(AppAttestKey.key_id == evidence.key_id)
            .with_for_update()
        ).scalar_one_or_none()
        if (
            device is None
            or device.attestation_state == "revoked"
            or key is None
            or key.installation_id != installation_id
            or key.status != "valid"
            or (key.device_id is not None and key.device_id != device_id)
        ):
            raise AttestationRejected("App Attest key cannot bind to this device")
        if evidence.kind == "attestation":
            database.execute(
                update(AppAttestKey)
                .where(
                    AppAttestKey.installation_id == installation_id,
                    AppAttestKey.key_id != key.key_id,
                    AppAttestKey.status == "valid",
                )
                .values(
                    status="revoked",
                    revoked_at=self._clock.now(),
                    revocation_reason="keyRotated",
                )
            )
        key.device_id = device_id

    def revoke_installation(
        self,
        database: Session,
        *,
        installation_id: str,
        reason: str,
    ) -> None:
        now = self._clock.now()
        database.execute(
            update(AppAttestKey)
            .where(
                AppAttestKey.installation_id == installation_id,
                AppAttestKey.status == "valid",
            )
            .values(
                status="revoked",
                revoked_at=now,
                revocation_reason=reason[:128],
            )
        )
        database.execute(
            update(Device)
            .where(Device.installation_id == installation_id)
            .values(attestation_state="revoked")
        )

    def _revoke_key(
        self,
        database: Session,
        key: AppAttestKey,
        *,
        reason: str,
    ) -> None:
        key.status = "revoked"
        key.revoked_at = self._clock.now()
        key.revocation_reason = reason
        if key.device_id is not None:
            device = database.get(Device, key.device_id)
            if device is not None:
                device.attestation_state = "revoked"

    def _validate_client_data(
        self,
        client_data: bytes,
        *,
        challenge: str,
        challenge_id: UUID,
        installation_id: str,
        purpose: AppAttestPurpose,
        method: str,
        path: str,
        body_sha256: str | None,
    ) -> None:
        try:
            value = json.loads(client_data)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise AttestationRejected("assertion client data is invalid") from error
        expected = {
            "bodySHA256": body_sha256,
            "challenge": challenge,
            "challengeID": str(challenge_id),
            "installationID": installation_id,
            "method": method.upper(),
            "path": path,
            "purpose": purpose.value,
        }
        if not isinstance(value, dict) or value != expected:
            raise AttestationRejected("assertion is not bound to this request")


def _decode_base64(value: str, *, maximum: int) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise AttestationRejected("App Attest value is not valid base64") from error
    if not decoded or len(decoded) > maximum:
        raise AttestationRejected("App Attest value size is invalid")
    return decoded


def _decode_cbor_mapping(value: bytes) -> dict[object, object]:
    try:
        decoded = cbor2.loads(value)
    except (cbor2.CBORDecodeError, ValueError) as error:
        raise AttestationRejected("App Attest value is not valid CBOR") from error
    if not isinstance(decoded, dict):
        raise AttestationRejected("App Attest CBOR root is not a map")
    return decoded


def _load_certificates(values: list[object]) -> list[x509.Certificate]:
    certificates: list[x509.Certificate] = []
    for value in values:
        assert isinstance(value, bytes)
        try:
            certificates.append(x509.load_der_x509_certificate(value))
        except ValueError as error:
            raise AttestationRejected("attestation certificate is invalid") from error
    return certificates


def _verify_certificate_signature(
    certificate: x509.Certificate,
    issuer: x509.Certificate,
) -> None:
    key = issuer.public_key()
    if not isinstance(key, ec.EllipticCurvePublicKey):
        raise AttestationRejected("App Attest certificate issuer is not EC")
    algorithm = certificate.signature_hash_algorithm
    if algorithm is None:
        raise AttestationRejected("certificate signature algorithm is invalid")
    try:
        key.verify(
            certificate.signature,
            certificate.tbs_certificate_bytes,
            ec.ECDSA(algorithm),
        )
    except InvalidSignature as error:
        raise AttestationRejected("certificate signature is invalid") from error


def _attested_auth_data(value: bytes) -> tuple[bytes, int, bytes, bytes]:
    if len(value) < 55 or not value[32] & 0x40:
        raise AttestationRejected("attested authenticator data is invalid")
    rp_id_hash = value[:32]
    counter = int.from_bytes(value[33:37], "big")
    aaguid = value[37:53]
    credential_length = int.from_bytes(value[53:55], "big")
    end = 55 + credential_length
    if credential_length != 32 or len(value) <= end:
        raise AttestationRejected("attested credential data is invalid")
    return rp_id_hash, counter, aaguid, value[55:end]


def _der_octet_strings(value: bytes) -> Iterator[bytes]:
    tag, content, end = _read_der_value(value, 0)
    if end != len(value) or tag != 0x30:
        raise AttestationRejected("nonce extension DER is invalid")
    yield from _walk_der_octets(content)


def _walk_der_octets(value: bytes) -> Iterator[bytes]:
    offset = 0
    while offset < len(value):
        tag, content, offset = _read_der_value(value, offset)
        if tag == 0x04:
            if len(content) == 32:
                yield content
            else:
                try:
                    inner_tag, inner_content, inner_end = _read_der_value(content, 0)
                except AttestationRejected:
                    continue
                if (
                    inner_tag == 0x04
                    and inner_end == len(content)
                    and len(inner_content) == 32
                ):
                    yield inner_content
        elif tag & 0x20 or tag & 0xC0 == 0x80:
            yield from _walk_der_octets(content)


def _read_der_value(value: bytes, offset: int) -> tuple[int, bytes, int]:
    if offset + 2 > len(value):
        raise AttestationRejected("truncated DER value")
    tag = value[offset]
    first_length = value[offset + 1]
    cursor = offset + 2
    if first_length & 0x80:
        length_bytes = first_length & 0x7F
        if length_bytes == 0 or length_bytes > 4 or cursor + length_bytes > len(value):
            raise AttestationRejected("invalid DER length")
        length = int.from_bytes(value[cursor : cursor + length_bytes], "big")
        cursor += length_bytes
    else:
        length = first_length
    end = cursor + length
    if end > len(value):
        raise AttestationRejected("truncated DER content")
    return tag, value[cursor:end], end
