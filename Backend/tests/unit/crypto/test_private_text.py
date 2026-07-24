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
