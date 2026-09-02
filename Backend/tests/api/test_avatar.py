"""The photo a cook chose for themselves.

`PUT /v1/auth/avatar` takes the JPEG the device produced, stores it in the
private bucket and answers with the profile; `DELETE` takes it away again.
What the tests below hold is the part that is not obvious from the routes:
the object is never deleted inline but queued, the served URL is signed and
minted from the stored key rather than the provider's link, and signing in
again never takes the cook's picture back.
"""

from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.auth.google import GoogleCredential
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.db.models import ObjectDeletionQueue, User
from ladle.db.session import build_engine
from tests.fakes.object_storage import FakeObjectStorage
from tests.integration.test_migrations import alembic_config

JPEG = b"\xff\xd8\xff\xe0" + b"a JPEG as far as the route is concerned" * 8
JPEG_HEADERS = {"Content-Type": "image/jpeg"}
GOOGLE_PICTURE = "https://lh3.googleusercontent.com/priya"


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class FakeGoogleCredentials:
    picture: str | None = GOOGLE_PICTURE
    calls: list[str] = field(default_factory=list)

    def verify(self, identity_token: str) -> GoogleCredential:
        self.calls.append(identity_token)
        return GoogleCredential(
            subject="avatar-google-subject",
            name="Priya Raman",
            picture=self.picture,
        )


def _build(
    database_url: str,
    *,
    storage: FakeObjectStorage | None = None,
    google: FakeGoogleCredentials | None = None,
) -> tuple[object, FakeObjectStorage, FakeGoogleCredentials]:
    command.upgrade(alembic_config(database_url), "head")
    engine = build_engine(database_url)
    clock = FrozenClock(datetime(2026, 9, 2, 9, 41, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    sessions = SessionService(
        access_tokens=access_tokens,
        refresh_tokens=RefreshTokenCodec(),
        refresh_lifetime=timedelta(days=30),
        rotation_grace=timedelta(seconds=5),
        clock=clock,
    )
    object_storage = storage if storage is not None else FakeObjectStorage()
    credentials = google if google is not None else FakeGoogleCredentials()
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        session_service=sessions,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        google_credentials=credentials,
        object_storage=object_storage,
    )
    return app, object_storage, credentials


def _guest(
    client: TestClient, installation: str = "avatar-device"
) -> dict[str, object]:
    guest: dict[str, object] = client.post(
        "/v1/auth/guest",
        json={"installationID": installation, "attestation": None},
    ).json()
    return guest


def _sign_in(
    client: TestClient,
    installation: str = "avatar-device",
    *,
    guest: dict[str, object] | None = None,
) -> dict[str, object]:
    existing = guest if guest is not None else _guest(client, installation)
    signed_in = client.post(
        "/v1/auth/google",
        json={
            "identityToken": "signed-google-id-token",
            "idempotencyKey": f"avatar-google-{installation}",
        },
        headers={"Authorization": f"Bearer {existing['accessToken']}"},
    )
    assert signed_in.status_code == 200
    result: dict[str, object] = signed_in.json()
    return result


def _upload(client: TestClient, tokens: dict[str, object]) -> dict[str, object]:
    response = client.put(
        "/v1/auth/avatar",
        content=JPEG,
        headers={**JPEG_HEADERS, "Authorization": f"Bearer {tokens['accessToken']}"},
    )
    assert response.status_code == 200
    uploaded: dict[str, object] = response.json()
    return uploaded


def _queued(database_url: str) -> dict[str, str]:
    engine = build_engine(database_url)
    with Session(engine) as database:
        queued = {
            entry.object_key: entry.reason
            for entry in database.scalars(select(ObjectDeletionQueue))
        }
    engine.dispose()
    return queued


@pytest.mark.integration
def test_uploading_a_photo_stores_it_and_serves_a_signed_url(
    clean_postgres_url: str,
) -> None:
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        assert tokens["avatarURL"] == GOOGLE_PICTURE
        assert tokens["avatarIsCustom"] is False

        response = client.put(
            "/v1/auth/avatar",
            content=JPEG,
            headers={
                **JPEG_HEADERS,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        )

    assert response.status_code == 200
    profile = response.json()
    user_id = tokens["userID"]
    assert profile["avatarIsCustom"] is True
    assert len(storage.objects) == 1
    key = next(iter(storage.objects))
    assert key.startswith(f"avatars/{user_id}/")
    assert key.endswith(".jpg")
    assert storage.objects[key] == (JPEG, "image/jpeg")
    assert profile["avatarURL"] == storage.signed_read_url(
        key,
        expires_in=timedelta(hours=6),
    )
    assert GOOGLE_PICTURE not in profile["avatarURL"]


@pytest.mark.integration
def test_a_second_upload_queues_the_object_it_replaced(
    clean_postgres_url: str,
) -> None:
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        headers = {**JPEG_HEADERS, "Authorization": f"Bearer {tokens['accessToken']}"}
        first = client.put("/v1/auth/avatar", content=JPEG, headers=headers).json()
        second = client.put(
            "/v1/auth/avatar",
            content=JPEG + b"the second one",
            headers=headers,
        ).json()

    assert first["avatarURL"] != second["avatarURL"]
    assert len(storage.objects) == 2, "the old object is queued, not deleted inline"
    engine = build_engine(clean_postgres_url)
    with Session(engine) as database:
        queued = {
            entry.object_key: entry.reason
            for entry in database.scalars(select(ObjectDeletionQueue))
        }
    engine.dispose()
    replaced = next(key for key in storage.objects if key in first["avatarURL"])
    assert queued == {replaced: "avatarReplaced"}


@pytest.mark.integration
def test_removing_a_photo_clears_the_key_and_queues_the_object(
    clean_postgres_url: str,
) -> None:
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        headers = {"Authorization": f"Bearer {tokens['accessToken']}"}
        client.put("/v1/auth/avatar", content=JPEG, headers={**headers, **JPEG_HEADERS})
        removed = client.delete("/v1/auth/avatar", headers=headers)

    assert removed.status_code == 200
    profile = removed.json()
    # Back to the provider's copy: removing the cook's photo is not the same
    # as having none.
    assert profile["avatarURL"] == GOOGLE_PICTURE
    assert profile["avatarIsCustom"] is False
    engine = build_engine(clean_postgres_url)
    with Session(engine) as database:
        stored = database.get(User, tokens["userID"])
        assert stored is not None
        assert stored.avatar_object_key is None
        queued = {
            entry.object_key: entry.reason
            for entry in database.scalars(select(ObjectDeletionQueue))
        }
    engine.dispose()
    assert queued == {next(iter(storage.objects)): "avatarRemoved"}


@pytest.mark.integration
def test_removing_a_photo_that_was_never_chosen_changes_nothing(
    clean_postgres_url: str,
) -> None:
    app, _, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        removed = client.delete(
            "/v1/auth/avatar",
            headers={"Authorization": f"Bearer {tokens['accessToken']}"},
        )

    assert removed.status_code == 200
    assert removed.json()["avatarURL"] == GOOGLE_PICTURE
    engine = build_engine(clean_postgres_url)
    with Session(engine) as database:
        assert database.scalars(select(ObjectDeletionQueue)).all() == []
    engine.dispose()


@pytest.mark.integration
def test_an_oversize_body_is_refused(clean_postgres_url: str) -> None:
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        response = client.put(
            "/v1/auth/avatar",
            content=JPEG + b"\x00" * (512 * 1024),
            headers={
                **JPEG_HEADERS,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        )

    assert response.status_code == 413
    assert response.json()["error"]["code"] == "invalidRequest"
    assert storage.objects == {}


@pytest.mark.integration
@pytest.mark.parametrize(
    ("body", "content_type", "expected"),
    [
        (b"\x89PNG\r\n\x1a\n" + b"not a JPEG", "image/jpeg", 400),
        (b"", "image/jpeg", 400),
        (JPEG, "image/png", 415),
        (JPEG, "application/octet-stream", 415),
    ],
)
def test_a_body_that_is_not_a_jpeg_is_refused(
    clean_postgres_url: str,
    body: bytes,
    content_type: str,
    expected: int,
) -> None:
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        response = client.put(
            "/v1/auth/avatar",
            content=body,
            headers={
                "Content-Type": content_type,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        )

    assert response.status_code == expected
    assert storage.objects == {}


@pytest.mark.integration
def test_the_avatar_belongs_to_a_signed_in_cook(clean_postgres_url: str) -> None:
    app, _, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        assert (
            client.put("/v1/auth/avatar", content=JPEG, headers=JPEG_HEADERS)
        ).status_code == 401
        assert client.delete("/v1/auth/avatar").status_code == 401


@pytest.mark.integration
def test_signing_in_with_google_again_leaves_the_cooks_photo_in_place(
    clean_postgres_url: str,
) -> None:
    """The provider's copy still refreshes; it just stops being what is served.

    A cook who picks a photo and signs in again on another device must get
    their own picture back, not Google's.
    """
    google = FakeGoogleCredentials(picture=GOOGLE_PICTURE)
    app, storage, _ = _build(clean_postgres_url, google=google)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        uploaded = client.put(
            "/v1/auth/avatar",
            content=JPEG,
            headers={
                **JPEG_HEADERS,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        ).json()

        google.picture = "https://lh3.googleusercontent.com/priya-new"
        again = _sign_in(client)

    assert again["avatarURL"] == uploaded["avatarURL"]
    assert again["avatarIsCustom"] is True
    engine = build_engine(clean_postgres_url)
    with Session(engine) as database:
        stored = database.get(User, tokens["userID"])
        assert stored is not None
        # Refreshed, as before — it is simply no longer the one served.
        assert stored.avatar_url == "https://lh3.googleusercontent.com/priya-new"
        assert stored.avatar_object_key == next(iter(storage.objects))
    engine.dispose()


@pytest.mark.integration
def test_the_photo_is_re_signed_on_every_refresh(clean_postgres_url: str) -> None:
    """There is no endpoint that re-signs an avatar URL, on purpose.

    The profile travels with the tokens, so the refresh the app already does
    every fifteen minutes is what keeps the signed URL live.
    """
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        uploaded = client.put(
            "/v1/auth/avatar",
            content=JPEG,
            headers={
                **JPEG_HEADERS,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        ).json()
        refreshed = client.post(
            "/v1/auth/refresh",
            json={
                "refreshToken": tokens["refreshToken"],
                "deviceID": tokens["deviceID"],
            },
        )

    assert refreshed.status_code == 200
    assert refreshed.json()["avatarURL"] == uploaded["avatarURL"]
    assert refreshed.json()["avatarIsCustom"] is True
    assert next(iter(storage.objects)) in uploaded["avatarURL"]


@pytest.mark.integration
def test_a_photo_needs_somewhere_to_put_it(clean_postgres_url: str) -> None:
    """Object storage is optional in configuration, so the route says so."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 9, 2, 9, 41, tzinfo=UTC))
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        clock=clock,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        google_credentials=FakeGoogleCredentials(),
    )

    with TestClient(app) as client:
        tokens = _sign_in(client)
        response = client.put(
            "/v1/auth/avatar",
            content=JPEG,
            headers={
                **JPEG_HEADERS,
                "Authorization": f"Bearer {tokens['accessToken']}",
            },
        )

    assert response.status_code == 503
    engine.dispose()


@pytest.mark.integration
def test_deleting_the_account_queues_the_cooks_photo(
    clean_postgres_url: str,
) -> None:
    """The privacy policy says the picture goes with the account."""
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        tokens = _sign_in(client)
        _upload(client, tokens)
        deleted = client.request(
            "DELETE",
            "/v1/auth/account",
            headers={"Authorization": f"Bearer {tokens['accessToken']}"},
            json={
                "confirmation": "DELETE",
                "refreshToken": tokens["refreshToken"],
                "idempotencyKey": f"delete-{tokens['userID']}",
            },
        )

    assert deleted.status_code == 204
    assert _queued(clean_postgres_url) == {
        next(iter(storage.objects)): "accountDeletion"
    }


@pytest.mark.integration
def test_a_guests_photo_is_queued_when_they_sign_into_an_existing_account(
    clean_postgres_url: str,
) -> None:
    """A guest can choose a photo, then sign into an account that has its own.

    The destination keeps its picture — merging is not a way to overwrite one —
    and the guest's object is queued rather than left in the bucket with every
    row that named it gone.
    """
    app, storage, _ = _build(clean_postgres_url)

    with TestClient(app) as client:
        account = _sign_in(client, "first-device")
        kept = _upload(client, account)

        guest = _guest(client, "second-device")
        _upload(client, guest)
        merged = _sign_in(client, "second-device", guest=guest)

    assert merged["userID"] == account["userID"]
    assert merged["avatarURL"] == kept["avatarURL"]
    assert merged["avatarIsCustom"] is True
    orphan = next(key for key in storage.objects if key not in str(kept["avatarURL"]))
    assert _queued(clean_postgres_url) == {orphan: "accountMerge"}
