import pytest
from cryptography.exceptions import InvalidTag
from pydantic import SecretStr

from ladle.crypto.private_text import LocalPrivateTextCipher


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
