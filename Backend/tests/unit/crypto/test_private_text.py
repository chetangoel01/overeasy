import pytest
from cryptography.exceptions import InvalidTag
from pydantic import SecretStr

from ladle.crypto.private_text import (
    LocalPrivateTextCipher,
    VersionedPrivateTextCipher,
    build_private_text_cipher,
)


def test_private_text_is_randomized_authenticated_and_round_trips() -> None:
    cipher = LocalPrivateTextCipher(SecretStr("test-only-encryption-secret"))

    first = cipher.encrypt("Use exactly two cups; the caption is wrong.")
    second = cipher.encrypt("Use exactly two cups; the caption is wrong.")

    assert first != second
    assert b"two cups" not in first
    assert cipher.decrypt(first) == "Use exactly two cups; the caption is wrong."


def test_wrong_key_cannot_decrypt() -> None:
    first = LocalPrivateTextCipher(SecretStr("first-key"))
    second = LocalPrivateTextCipher(SecretStr("second-key"))

    with pytest.raises(InvalidTag):
        second.decrypt(first.encrypt("private correction"))


def test_private_text_byte_limit_accepts_exact_utf8_boundary() -> None:
    cipher = LocalPrivateTextCipher(SecretStr("test-only-encryption-secret"))

    encrypted = cipher.encrypt("é" * 100_000)

    assert cipher.decrypt(encrypted) == "é" * 100_000
    with pytest.raises(ValueError, match="length"):
        cipher.encrypt("é" * 100_001)


def test_versioned_cipher_records_key_id_and_decrypts_after_rotation() -> None:
    original = VersionedPrivateTextCipher(
        active_key_id="2026-q2",
        keys={"2026-q2": SecretStr("first-managed-secret")},
    )
    ciphertext = original.encrypt("private correction")
    rotated = VersionedPrivateTextCipher(
        active_key_id="2026-q3",
        keys={
            "2026-q2": SecretStr("first-managed-secret"),
            "2026-q3": SecretStr("second-managed-secret"),
        },
    )

    assert ciphertext.startswith(b"LPT2\x072026-q2")
    assert rotated.decrypt(ciphertext) == "private correction"
    assert rotated.encrypt("new private text").startswith(b"LPT2\x072026-q3")


def test_versioned_cipher_reads_legacy_ciphertext_during_migration() -> None:
    legacy_secret = SecretStr("legacy-managed-secret")
    legacy = LocalPrivateTextCipher(legacy_secret)
    rotated = VersionedPrivateTextCipher(
        active_key_id="2026-q3",
        keys={"2026-q3": SecretStr("new-managed-secret")},
        legacy_key=legacy_secret,
    )

    assert rotated.decrypt(legacy.encrypt("legacy private text")) == (
        "legacy private text"
    )


def test_versioned_cipher_rejects_unknown_or_invalid_key_ids() -> None:
    cipher = VersionedPrivateTextCipher(
        active_key_id="2026-q3",
        keys={"2026-q3": SecretStr("new-managed-secret")},
    )

    with pytest.raises(ValueError, match="key identifier"):
        cipher.decrypt(b"LPT2\x07missing" + b"\x00" * 32)
    with pytest.raises(ValueError, match="active"):
        VersionedPrivateTextCipher(
            active_key_id="missing",
            keys={"2026-q3": SecretStr("new-managed-secret")},
        )


def test_cipher_builder_uses_managed_keyring_when_configured() -> None:
    cipher = build_private_text_cipher(
        active_key_id="2026-q3",
        keyring_json=SecretStr(
            '{"2026-q2":"first-managed-secret","2026-q3":"second-managed-secret"}'
        ),
        legacy_key=SecretStr("legacy-managed-secret"),
    )

    assert cipher.encrypt("managed private text").startswith(b"LPT2\x072026-q3")
