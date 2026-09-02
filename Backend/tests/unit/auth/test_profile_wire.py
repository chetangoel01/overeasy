"""The account's creation date on the wire.

The Profile screen greets a cook with "cooking since August 2026", which is
the one fact on it the client cannot derive: the library knows how many
recipes it holds, but only the server knows when the account started. So
`created_at` rides on the tokens the way the profile already does, and on
the profile response the name edit returns.

It is server-owned in the strong sense: there is no request field for it,
and `ProfileUpdateRequest` forbids extras, so a client cannot assert one.
"""

from datetime import UTC, datetime
from uuid import UUID

import pytest
from pydantic import ValidationError

from ladle.api.routes.auth import (
    AuthTokensResponse,
    ProfileResponse,
    ProfileUpdateRequest,
)
from ladle.auth.sessions import SessionTokens

CREATED_AT = datetime(2026, 8, 14, 12, 0, tzinfo=UTC)
EXPIRES_AT = datetime(2026, 9, 2, 9, 41, tzinfo=UTC)
USER_ID = UUID("40000000-0000-4000-8000-000000000001")
DEVICE_ID = UUID("50000000-0000-4000-8000-000000000001")


def _tokens(**overrides: object) -> SessionTokens:
    values: dict[str, object] = {
        "access_token": "access",
        "access_expires_at": EXPIRES_AT,
        "refresh_token": "refresh",
        "user_id": USER_ID,
        "device_id": DEVICE_ID,
        "user_kind": "google",
        "created_at": CREATED_AT,
        "display_name": "Priya Raman",
        "avatar_url": "https://example.com/avatar.jpg",
    }
    values.update(overrides)
    return SessionTokens(**values)  # type: ignore[arg-type]


def test_tokens_response_carries_the_accounts_creation_date() -> None:
    rendered = AuthTokensResponse.from_tokens(_tokens()).model_dump(
        mode="json", by_alias=True
    )

    assert rendered["createdAt"] == "2026-08-14T12:00:00.000Z"
    assert rendered["displayName"] == "Priya Raman"


def test_profile_response_carries_the_accounts_creation_date() -> None:
    rendered = ProfileResponse(
        user_kind="google",
        display_name="Priya Raman",
        avatar_url=None,
        created_at=CREATED_AT,
    ).model_dump(mode="json", by_alias=True)

    assert rendered["createdAt"] == "2026-08-14T12:00:00.000Z"
    assert rendered["avatarURL"] is None


def test_creation_date_is_required_on_both_responses() -> None:
    # Absent rather than nullable: every account has a creation date, and a
    # client that had to handle a missing one would need a second story for
    # a case the server cannot produce.
    with pytest.raises(ValidationError):
        AuthTokensResponse(
            access_token="access",
            access_token_expires_at=EXPIRES_AT,
            refresh_token=None,
            user_id=USER_ID,
            device_id=DEVICE_ID,
            user_kind="guest",
        )
    with pytest.raises(ValidationError):
        ProfileResponse(user_kind="guest")


def test_a_client_cannot_assert_its_own_creation_date() -> None:
    with pytest.raises(ValidationError):
        ProfileUpdateRequest.model_validate(
            {"displayName": "Priya Raman", "createdAt": "2020-01-01T00:00:00.000Z"}
        )
