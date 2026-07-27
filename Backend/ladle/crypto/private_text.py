import hashlib
import json
import os
import re
from typing import Protocol

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from pydantic import SecretStr

_LEGACY_VERSION = b"LPT1"
_VERSION = b"LPT2"
_NONCE_BYTES = 12
_MAX_KEY_ID_BYTES = 64
_KEY_ID_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
MAX_PRIVATE_TEXT_BYTES = 200_000


class PrivateTextCipher(Protocol):
    def encrypt(self, value: str) -> bytes: ...

    def decrypt(self, value: bytes) -> str: ...


class LocalPrivateTextCipher:
    """Legacy development cipher retained only to read existing LPT1 values."""

    def __init__(self, secret: SecretStr) -> None:
        key = hashlib.sha256(secret.get_secret_value().encode()).digest()
        self._cipher = AESGCM(key)

    def encrypt(self, value: str) -> bytes:
        encoded = validate_private_text(value).encode()
        nonce = os.urandom(_NONCE_BYTES)
        encrypted = self._cipher.encrypt(nonce, encoded, _LEGACY_VERSION)
        return _LEGACY_VERSION + nonce + encrypted

    def decrypt(self, value: bytes) -> str:
        if not value.startswith(_LEGACY_VERSION):
            raise ValueError("private text version is invalid")
        nonce_start = len(_LEGACY_VERSION)
        nonce_end = nonce_start + _NONCE_BYTES
        if len(value) <= nonce_end:
            raise ValueError("private text payload is invalid")
        plaintext = self._cipher.decrypt(
            value[nonce_start:nonce_end],
            value[nonce_end:],
            _LEGACY_VERSION,
        )
        return plaintext.decode()


class VersionedPrivateTextCipher:
    """Authenticated envelope encryption with an explicit managed key ID."""

    def __init__(
        self,
        *,
        active_key_id: str,
        keys: dict[str, SecretStr],
        legacy_key: SecretStr | None = None,
    ) -> None:
        if not _KEY_ID_PATTERN.fullmatch(active_key_id):
            raise ValueError("active encryption key identifier is invalid")
        if active_key_id not in keys:
            raise ValueError("active encryption key identifier is unavailable")
        if not keys:
            raise ValueError("encryption keyring cannot be empty")
        for key_id in keys:
            if not _KEY_ID_PATTERN.fullmatch(key_id):
                raise ValueError("encryption key identifier is invalid")
        self._active_key_id = active_key_id
        self._ciphers = {
            key_id: AESGCM(_derive_key(secret)) for key_id, secret in keys.items()
        }
        self._legacy = (
            LocalPrivateTextCipher(legacy_key) if legacy_key is not None else None
        )

    def encrypt(self, value: str) -> bytes:
        encoded = validate_private_text(value).encode()
        key_id = self._active_key_id.encode("ascii")
        header = _VERSION + bytes([len(key_id)]) + key_id
        nonce = os.urandom(_NONCE_BYTES)
        encrypted = self._ciphers[self._active_key_id].encrypt(
            nonce,
            encoded,
            header,
        )
        return header + nonce + encrypted

    def decrypt(self, value: bytes) -> str:
        if value.startswith(_LEGACY_VERSION):
            if self._legacy is None:
                raise ValueError("legacy private text key is unavailable")
            return self._legacy.decrypt(value)
        if not value.startswith(_VERSION) or len(value) <= len(_VERSION):
            raise ValueError("private text version is invalid")
        key_id_size = value[len(_VERSION)]
        if key_id_size == 0 or key_id_size > _MAX_KEY_ID_BYTES:
            raise ValueError("private text key identifier is invalid")
        key_id_start = len(_VERSION) + 1
        key_id_end = key_id_start + key_id_size
        nonce_end = key_id_end + _NONCE_BYTES
        if len(value) <= nonce_end:
            raise ValueError("private text payload is invalid")
        try:
            key_id = value[key_id_start:key_id_end].decode("ascii")
        except UnicodeDecodeError as error:
            raise ValueError("private text key identifier is invalid") from error
        cipher = self._ciphers.get(key_id)
        if cipher is None:
            raise ValueError("private text key identifier is unavailable")
        header = value[:key_id_end]
        plaintext = cipher.decrypt(
            value[key_id_end:nonce_end],
            value[nonce_end:],
            header,
        )
        return plaintext.decode()


def build_private_text_cipher(
    *,
    active_key_id: str | None,
    keyring_json: SecretStr | None,
    legacy_key: SecretStr,
) -> PrivateTextCipher:
    if active_key_id is None and keyring_json is None:
        return LocalPrivateTextCipher(legacy_key)
    if active_key_id is None or keyring_json is None:
        raise ValueError(
            "encryption active key identifier and keyring must be configured together"
        )
    try:
        raw_keys = json.loads(keyring_json.get_secret_value())
    except json.JSONDecodeError as error:
        raise ValueError("encryption keyring must be valid JSON") from error
    if not isinstance(raw_keys, dict) or not raw_keys:
        raise ValueError("encryption keyring must be a nonempty object")
    keys: dict[str, SecretStr] = {}
    for key_id, value in raw_keys.items():
        if not isinstance(key_id, str) or not isinstance(value, str) or not value:
            raise ValueError("encryption keyring entries must be string secrets")
        keys[key_id] = SecretStr(value)
    return VersionedPrivateTextCipher(
        active_key_id=active_key_id,
        keys=keys,
        legacy_key=legacy_key,
    )


def _derive_key(secret: SecretStr) -> bytes:
    return hashlib.sha256(secret.get_secret_value().encode()).digest()


def validate_private_text(value: str) -> str:
    encoded = value.encode()
    if not encoded or len(encoded) > MAX_PRIVATE_TEXT_BYTES:
        raise ValueError("private text length is invalid")
    return value
