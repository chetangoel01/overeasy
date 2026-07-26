import base64
import hashlib
from datetime import UTC, datetime, timedelta

import cbor2
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from ladle.auth.attestation import (
    AppleAppAttestVerifier,
    AttestationRejected,
)

APP_ID = "ABCDE12345.com.ladle.ios"
NOW = datetime(2026, 7, 26, 16, 0, tzinfo=UTC)


class FrozenClock:
    def now(self) -> datetime:
        return NOW


def _certificate(
    *,
    subject: x509.Name,
    issuer: x509.Name,
    public_key: ec.EllipticCurvePublicKey,
    issuer_key: ec.EllipticCurvePrivateKey,
    ca: bool,
    nonce: bytes | None = None,
) -> x509.Certificate:
    builder = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(public_key)
        .serial_number(x509.random_serial_number())
        .not_valid_before(NOW - timedelta(days=1))
        .not_valid_after(NOW + timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
    )
    if nonce is not None:
        der = b"\x30\x24\xa1\x22\x04\x20" + nonce
        builder = builder.add_extension(
            x509.UnrecognizedExtension(
                x509.ObjectIdentifier("1.2.840.113635.100.8.2"),
                der,
            ),
            critical=False,
        )
    return builder.sign(issuer_key, hashes.SHA256())


def _fixture() -> tuple[bytes, str, bytes, ec.EllipticCurvePrivateKey]:
    challenge = b"fresh-server-challenge"
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    uncompressed = leaf_key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    key_id_bytes = hashlib.sha256(uncompressed).digest()
    key_id = base64.b64encode(key_id_bytes).decode("ascii")
    app_hash = hashlib.sha256(APP_ID.encode()).digest()
    auth_data = (
        app_hash
        + b"\x40"
        + b"\0\0\0\0"
        + (b"appattest" + b"\0" * 7)
        + len(key_id_bytes).to_bytes(2, "big")
        + key_id_bytes
        + cbor2.dumps({1: 2, 3: -7})
    )
    nonce = hashlib.sha256(auth_data + hashlib.sha256(challenge).digest()).digest()

    root_key = ec.generate_private_key(ec.SECP384R1())
    intermediate_key = ec.generate_private_key(ec.SECP384R1())
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test Root")])
    intermediate_name = x509.Name(
        [x509.NameAttribute(NameOID.COMMON_NAME, "Test Intermediate")]
    )
    leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "App Attest")])
    root = _certificate(
        subject=root_name,
        issuer=root_name,
        public_key=root_key.public_key(),
        issuer_key=root_key,
        ca=True,
    )
    intermediate = _certificate(
        subject=intermediate_name,
        issuer=root_name,
        public_key=intermediate_key.public_key(),
        issuer_key=root_key,
        ca=True,
    )
    leaf = _certificate(
        subject=leaf_name,
        issuer=intermediate_name,
        public_key=leaf_key.public_key(),
        issuer_key=intermediate_key,
        ca=False,
        nonce=nonce,
    )
    attestation = cbor2.dumps(
        {
            "fmt": "apple-appattest",
            "attStmt": {
                "x5c": [
                    leaf.public_bytes(serialization.Encoding.DER),
                    intermediate.public_bytes(serialization.Encoding.DER),
                ],
                "receipt": b"apple-receipt",
            },
            "authData": auth_data,
        }
    )
    root_pem = root.public_bytes(serialization.Encoding.PEM)
    return root_pem, key_id, attestation, leaf_key


def test_real_verifier_validates_attestation_and_monotonic_assertion() -> None:
    root, key_id, attestation, leaf_key = _fixture()
    verifier = AppleAppAttestVerifier(
        app_id=APP_ID,
        environment="production",
        clock=FrozenClock(),
        trusted_root_pem=root,
    )
    verified = verifier.verify_attestation(
        key_id=key_id,
        challenge=b"fresh-server-challenge",
        attestation_object=attestation,
    )
    client_data = b'{"challenge":"fresh"}'
    auth_data = (
        hashlib.sha256(APP_ID.encode()).digest() + b"\0" + (7).to_bytes(4, "big")
    )
    signature = leaf_key.sign(
        auth_data + hashlib.sha256(client_data).digest(),
        ec.ECDSA(hashes.SHA256()),
    )
    assertion = cbor2.dumps(
        {
            "signature": signature,
            "authenticatorData": auth_data,
        }
    )

    counter = verifier.verify_assertion(
        public_key=verified.public_key,
        client_data=client_data,
        assertion=assertion,
    )

    assert counter == 7
    assert verified.receipt == b"apple-receipt"
    assert verified.environment == "production"


def test_real_verifier_rejects_wrong_challenge_and_tampered_assertion() -> None:
    root, key_id, attestation, leaf_key = _fixture()
    verifier = AppleAppAttestVerifier(
        app_id=APP_ID,
        environment="production",
        clock=FrozenClock(),
        trusted_root_pem=root,
    )
    with pytest.raises(AttestationRejected):
        verifier.verify_attestation(
            key_id=key_id,
            challenge=b"replayed-challenge",
            attestation_object=attestation,
        )

    public_key = leaf_key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    with pytest.raises(AttestationRejected):
        verifier.verify_assertion(
            public_key=public_key,
            client_data=b"bound request",
            assertion=cbor2.dumps(
                {
                    "signature": b"tampered",
                    "authenticatorData": (
                        hashlib.sha256(APP_ID.encode()).digest()
                        + b"\0"
                        + (1).to_bytes(4, "big")
                    ),
                }
            ),
        )
