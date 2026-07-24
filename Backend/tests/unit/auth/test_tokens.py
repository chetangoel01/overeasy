from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest

from ladle.auth.tokens import (
    AccessTokenCodec,
    AccessTokenExpired,
    RefreshTokenCodec,
)

NOW = datetime(2030, 7, 23, 21, 0, tzinfo=UTC)


def test_refresh_tokens_are_random_opaque_and_verified_by_hash() -> None:
    codec = RefreshTokenCodec()
    session_id = uuid4()

    first = codec.issue(session_id)
    second = codec.issue(session_id)

    assert first.value != second.value
    assert first.digest != second.digest
    assert first.value.encode() not in first.digest
    assert codec.session_id(first.value) == session_id
    assert codec.matches(first.value, first.digest)
    assert not codec.matches(second.value, first.digest)


def test_access_token_claims_and_expiry_use_injected_time() -> None:
    codec = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    user_id = uuid4()
    session_id = uuid4()
    device_id = uuid4()

    issued = codec.issue(
        user_id=user_id,
        session_id=session_id,
        device_id=device_id,
        user_kind="guest",
        now=NOW,
    )
    claims = codec.decode(issued.value, now=NOW + timedelta(minutes=14))

    assert claims.user_id == user_id
    assert claims.session_id == session_id
    assert claims.device_id == device_id
    assert claims.user_kind == "guest"
    assert issued.expires_at == NOW + timedelta(minutes=15)

    with pytest.raises(AccessTokenExpired):
        codec.decode(issued.value, now=NOW + timedelta(minutes=15))
