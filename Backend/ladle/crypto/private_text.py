import hashlib
import os
from typing import Protocol

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import SecretStr

_VERSION = b"LPT1"
_NONCE_BYTES = 12
_MAX_PLAINTEXT_BYTES = 200_000


class PrivateTextCipher(Protocol):
    def encrypt(self, value: str) -> bytes: ...

    def decrypt(self, value: bytes) -> str: ...


class LocalPrivateTextCipher:
    """Development KMS substitute using randomized authenticated encryption."""

    def __init__(self, secret: SecretStr) -> None:
        key = hashlib.sha256(secret.get_secret_value().encode()).digest()
        self._cipher = AESGCM(key)

    def encrypt(self, value: str) -> bytes:
        encoded = value.encode()
        if not encoded or len(encoded) > _MAX_PLAINTEXT_BYTES:
            raise ValueError("private text length is invalid")
        nonce = os.urandom(_NONCE_BYTES)
        encrypted = self._cipher.encrypt(nonce, encoded, _VERSION)
        return _VERSION + nonce + encrypted

    def decrypt(self, value: bytes) -> str:
        if not value.startswith(_VERSION):
            raise ValueError("private text version is invalid")
        nonce_start = len(_VERSION)
        nonce_end = nonce_start + _NONCE_BYTES
        if len(value) <= nonce_end:
            raise ValueError("private text payload is invalid")
        plaintext = self._cipher.decrypt(
            value[nonce_start:nonce_end],
            value[nonce_end:],
            _VERSION,
        )
        return plaintext.decode()
