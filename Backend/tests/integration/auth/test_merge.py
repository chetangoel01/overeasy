from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from threading import Barrier
from uuid import UUID, uuid4

import pytest
from sqlalchemy import func, select
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.auth.merge import (
    AccountMergeInvalid,
    AccountMergeService,
    SignInProfile,
)
from ladle.auth.tokens import RefreshTokenCodec
from ladle.db.models import (
    AppleIdentity,
    AuthSession,
    Device,
    DiscoverImpression,
    GoogleIdentity,
    ImportJob,
    ImportQuotaEvent,
    Recipe,
    RecipeChange,
    RecipeSlotReservation,
    SourceVideo,
    User,
    UserSyncState,
)
from ladle.db.session import build_engine
from tests.integration.auth.test_sessions import service
from tests.integration.imports.test_reservations import seed_saved_recipe
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


def seed_user(database: Session, *, kind: str, now: datetime) -> UUID:
    user_id = uuid4()
    database.add(User(id=user_id, kind=kind, created_at=now))
    database.add(UserSyncState(user_id=user_id, next_sequence=1))
    database.flush()
    return user_id


@pytest.mark.integration
def test_first_apple_sign_in_upgrades_guest_and_revokes_guest_sessions(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    sessions = service(clock)
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())
        device = Device(
            id=uuid4(),
            user_id=guest_id,
            installation_id="first-apple-device",
            attestation_state="development",
            created_at=clock.now(),
            last_seen_at=clock.now(),
        )
        database.add(device)
        database.flush()
        guest_tokens = sessions.create(
            database,
            user_id=guest_id,
            device_id=device.id,
        )

    with Session(engine) as database, database.begin():
        destination_id = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="stable-first-subject",
            idempotency_key="first-upgrade",
        )

    assert destination_id == guest_id
    with Session(engine) as database:
        user = database.get(User, guest_id)
        identity = database.get(AppleIdentity, "stable-first-subject")
        stored_session = database.get(
            AuthSession,
            RefreshTokenCodec().session_id(guest_tokens.refresh_token or ""),
        )
        assert user is not None
        assert user.kind == "apple"
        assert identity is not None
        assert identity.user_id == guest_id
        assert stored_session is not None
        assert stored_session.revoked_at == clock.now()

    engine.dispose()


@pytest.mark.integration
def test_concurrent_merge_retry_emits_destination_changes_once(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    database_sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)
    with database_sessions.begin() as database:
        guest_id = seed_user(database, kind="guest", now=clock.now())
        destination_id = seed_user(database, kind="apple", now=clock.now())
        database.add(
            AppleIdentity(
                apple_sub="concurrent-apple-subject",
                user_id=destination_id,
                created_at=clock.now(),
            )
        )
        seed_saved_recipe(database, user_id=guest_id, index=1)

    rendezvous = Barrier(3)

    def merge_once() -> UUID:
        with database_sessions.begin() as database:
            rendezvous.wait()
            return merger.merge(
                database,
                guest_user_id=guest_id,
                apple_subject="concurrent-apple-subject",
                idempotency_key="same-concurrent-attempt",
            )

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(merge_once)
        second = executor.submit(merge_once)
        rendezvous.wait()
        results = [first.result(timeout=5), second.result(timeout=5)]

    assert results == [destination_id, destination_id]
    with database_sessions() as database:
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeChange)
                .where(RecipeChange.user_id == destination_id)
            )
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_existing_apple_account_merge_preserves_data_and_is_idempotent(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    sessions = service(clock)
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())
        destination_id = seed_user(database, kind="apple", now=clock.now())
        database.add(
            AppleIdentity(
                apple_sub="existing-apple-subject",
                user_id=destination_id,
                created_at=clock.now(),
            )
        )
        device = Device(
            id=uuid4(),
            user_id=guest_id,
            installation_id="merge-device",
            attestation_state="development",
            created_at=clock.now(),
            last_seen_at=clock.now(),
        )
        database.add(device)
        seed_saved_recipe(database, user_id=guest_id, index=1)
        seed_saved_recipe(database, user_id=destination_id, index=2)
        database.flush()
        guest_recipe_id = database.scalar(
            select(Recipe.id).where(Recipe.user_id == guest_id)
        )
        assert guest_recipe_id is not None
        job_id = uuid4()
        database.add(
            ImportJob(
                id=job_id,
                user_id=guest_id,
                source_url="https://youtu.be/merged-job",
                canonical_url="https://www.youtube.com/watch?v=merged-job",
                source="youtube",
                status="ready",
                stage="completed",
                retry_count=0,
                bypass_cache=False,
                current_recipe_id=guest_recipe_id,
                idempotency_key="merged-job",
                created_at=clock.now(),
                updated_at=clock.now(),
                completed_at=clock.now(),
            )
        )
        database.flush()
        database.add(
            RecipeSlotReservation(
                id=uuid4(),
                user_id=guest_id,
                import_job_id=job_id,
                state="consumed",
                created_at=clock.now(),
                expires_at=clock.now() + timedelta(hours=1),
            )
        )
        database.add(
            ImportQuotaEvent(
                id=uuid4(),
                user_id=guest_id,
                import_job_id=job_id,
                operation="submit",
                event_key=f"{job_id}:submit",
                occurred_at=clock.now(),
            )
        )
        guest_tokens = sessions.create(
            database,
            user_id=guest_id,
            device_id=device.id,
        )

    with Session(engine) as database, database.begin():
        first = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="existing-apple-subject",
            idempotency_key="merge-attempt",
        )
    with Session(engine) as database, database.begin():
        second = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="existing-apple-subject",
            idempotency_key="merge-attempt",
        )

    assert first == second == destination_id
    with Session(engine) as database:
        guest = database.get(User, guest_id)
        moved_recipe = database.get(Recipe, guest_recipe_id)
        moved_job = database.get(ImportJob, job_id)
        moved_reservation = database.scalar(
            select(RecipeSlotReservation).where(
                RecipeSlotReservation.import_job_id == job_id
            )
        )
        moved_device = database.scalar(
            select(Device).where(Device.installation_id == "merge-device")
        )
        moved_quota = database.scalar(
            select(ImportQuotaEvent).where(ImportQuotaEvent.import_job_id == job_id)
        )
        old_session_id = RefreshTokenCodec().session_id(
            guest_tokens.refresh_token or ""
        )
        old_session = database.get(AuthSession, old_session_id)
        assert guest is not None
        assert guest.merged_into_user_id == destination_id
        assert moved_recipe is not None
        assert moved_recipe.user_id == destination_id
        assert moved_job is not None
        assert moved_job.user_id == destination_id
        assert moved_reservation is not None
        assert moved_reservation.user_id == destination_id
        assert moved_device is not None
        assert moved_device.user_id == destination_id
        assert moved_quota is not None
        assert moved_quota.user_id == destination_id
        assert old_session is not None
        assert old_session.revoked_at == clock.now()
        assert (
            database.scalar(
                select(func.count())
                .select_from(Recipe)
                .where(Recipe.user_id == destination_id)
            )
            == 2
        )
        destination_changes = list(
            database.scalars(
                select(RecipeChange).where(RecipeChange.user_id == destination_id)
            )
        )
        assert [change.recipe_id for change in destination_changes] == [guest_recipe_id]
        assert (
            database.scalar(
                select(func.count())
                .select_from(RecipeChange)
                .where(RecipeChange.user_id == guest_id)
            )
            == 0
        )

    engine.dispose()


@pytest.mark.integration
def test_a_user_with_an_apple_identity_cannot_claim_a_second_one(
    clean_postgres_url: str,
) -> None:
    """A second Apple ID on one account would leave a refresh token that
    account deletion never revokes: deletion looks up ONE identity row."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database, kind="guest", now=clock.now())

    with Session(engine) as database, database.begin():
        claimed = merger.merge(
            database,
            guest_user_id=user_id,
            apple_subject="first-apple-id",
            idempotency_key="first-sign-in",
            apple_refresh_token_encrypted=b"token-first",
        )
    assert claimed == user_id

    with (
        pytest.raises(AccountMergeInvalid),
        Session(engine) as database,
        database.begin(),
    ):
        merger.merge(
            database,
            guest_user_id=user_id,
            apple_subject="second-apple-id",
            idempotency_key="second-sign-in",
            apple_refresh_token_encrypted=b"token-second",
        )

    with Session(engine) as database:
        identities = list(
            database.scalars(
                select(AppleIdentity).where(AppleIdentity.user_id == user_id)
            )
        )
        assert [identity.apple_sub for identity in identities] == ["first-apple-id"]

    # The same-subject re-sign-in stays idempotent and refreshes the token.
    with Session(engine) as database, database.begin():
        again = merger.merge(
            database,
            guest_user_id=user_id,
            apple_subject="first-apple-id",
            idempotency_key="repeat-sign-in",
            apple_refresh_token_encrypted=b"token-rotated",
        )
    assert again == user_id
    with Session(engine) as database:
        refreshed = database.get(AppleIdentity, "first-apple-id")
        assert refreshed is not None
        assert refreshed.refresh_token_encrypted == b"token-rotated"

    engine.dispose()


@pytest.mark.integration
def test_a_user_with_a_google_identity_cannot_claim_a_second_one(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database, kind="guest", now=clock.now())

    with Session(engine) as database, database.begin():
        merger.merge_google(
            database,
            guest_user_id=user_id,
            google_subject="first-google-id",
            idempotency_key="first-google-sign-in",
        )

    with (
        pytest.raises(AccountMergeInvalid),
        Session(engine) as database,
        database.begin(),
    ):
        merger.merge_google(
            database,
            guest_user_id=user_id,
            google_subject="second-google-id",
            idempotency_key="second-google-sign-in",
        )

    with Session(engine) as database:
        subjects = list(
            database.scalars(
                select(GoogleIdentity.google_sub).where(
                    GoogleIdentity.user_id == user_id
                )
            )
        )
        assert subjects == ["first-google-id"]

    engine.dispose()


@pytest.mark.integration
def test_concurrent_claims_of_two_apple_identities_admit_exactly_one(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    database_sessions = sessionmaker(engine, expire_on_commit=False)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)
    with database_sessions.begin() as database:
        user_id = seed_user(database, kind="guest", now=clock.now())

    rendezvous = Barrier(3)

    def claim(subject: str) -> UUID | type[AccountMergeInvalid]:
        with database_sessions.begin() as database:
            rendezvous.wait()
            try:
                return merger.merge(
                    database,
                    guest_user_id=user_id,
                    apple_subject=subject,
                    idempotency_key=f"claim-{subject}",
                )
            except AccountMergeInvalid:
                return AccountMergeInvalid

    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(claim, "race-apple-a")
        second = executor.submit(claim, "race-apple-b")
        rendezvous.wait()
        results = [first.result(timeout=10), second.result(timeout=10)]

    assert sorted(results, key=str) == sorted([user_id, AccountMergeInvalid], key=str)
    with database_sessions() as database:
        assert (
            database.scalar(
                select(func.count())
                .select_from(AppleIdentity)
                .where(AppleIdentity.user_id == user_id)
            )
            == 1
        )

    engine.dispose()


@pytest.mark.integration
def test_sign_in_seeds_a_profile_but_never_overwrites_an_edited_name(
    clean_postgres_url: str,
) -> None:
    """The rule the whole feature rests on.

    Apple hands over a full name exactly once, so it is captured on first
    sign-in. After that the cook owns it: signing in again on a new device, or
    after a reinstall, must not quietly replace what they chose with what the
    provider said. The avatar has no local edit to lose, so it does refresh.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 9, 1, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())

    # First sign-in: nothing stored yet, so the provider seeds both fields.
    with Session(engine) as database, database.begin():
        merger.merge_google(
            database,
            guest_user_id=guest_id,
            google_subject="google-profile-subject",
            idempotency_key="first",
            profile=SignInProfile(
                display_name="Priya Raman",
                avatar_url="https://lh3.example/a/first.jpg",
            ),
        )

    with Session(engine) as database:
        user = database.get(User, guest_id)
        assert user is not None
        assert user.display_name == "Priya Raman"
        assert user.avatar_url == "https://lh3.example/a/first.jpg"

    # The cook renames themselves.
    with Session(engine) as database, database.begin():
        edited = database.get(User, guest_id)
        assert edited is not None
        edited.display_name = "Pri"

    # Signing in again: the name is theirs now, the avatar is still Google's.
    with Session(engine) as database, database.begin():
        merger.merge_google(
            database,
            guest_user_id=guest_id,
            google_subject="google-profile-subject",
            idempotency_key="second",
            profile=SignInProfile(
                display_name="Priya Raman",
                avatar_url="https://lh3.example/a/second.jpg",
            ),
        )

    with Session(engine) as database:
        user = database.get(User, guest_id)
        assert user is not None
        assert user.display_name == "Pri", "a later sign-in must not clobber an edit"
        assert user.avatar_url == "https://lh3.example/a/second.jpg"

    engine.dispose()


@pytest.mark.integration
def test_a_sign_in_carrying_no_profile_leaves_the_account_untouched(
    clean_postgres_url: str,
) -> None:
    """Apple supplies a name only on the first authorization, so every
    subsequent Apple sign-in arrives with nothing. That is ordinary, and it
    must not blank out what the first one captured."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 9, 1, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())

    with Session(engine) as database, database.begin():
        merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="apple-profile-subject",
            idempotency_key="first",
            profile=SignInProfile(display_name="Chetan Goel"),
        )

    with Session(engine) as database, database.begin():
        merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="apple-profile-subject",
            idempotency_key="second",
            profile=SignInProfile(),
        )

    with Session(engine) as database:
        user = database.get(User, guest_id)
        assert user is not None
        assert user.display_name == "Chetan Goel"
        assert user.avatar_url is None

    engine.dispose()


@pytest.mark.integration
def test_merge_carries_the_guest_discover_impressions_and_keeps_the_later_one(
    clean_postgres_url: str,
) -> None:
    """A cook who signs in keeps the feed they were reading.

    Impressions cannot simply be re-pointed the way recipes and devices are:
    both accounts may already hold a row for the same source, and the pair is
    the primary key. So they are upserted, the later `seen_at` winning, and
    the guest's copies removed — otherwise signing in would resurrect a feed
    the cook has already scrolled past, or lose the one they were on.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    merger = AccountMergeService(clock=clock)
    guest_seen = clock.now() - timedelta(hours=1)
    account_seen = clock.now() - timedelta(hours=3)
    sources = [uuid4() for _ in range(3)]

    with Session(engine) as database, database.begin():
        guest_id = seed_user(database, kind="guest", now=clock.now())
        destination_id = seed_user(database, kind="apple", now=clock.now())
        database.add(
            AppleIdentity(
                apple_sub="impression-apple-subject",
                user_id=destination_id,
                created_at=clock.now(),
            )
        )
        for index, source_id in enumerate(sources):
            database.add(
                SourceVideo(
                    id=source_id,
                    platform="tiktok",
                    platform_video_id=f"merge-impression-{index}",
                    canonical_url=(
                        f"https://www.tiktok.com/@cook/video/{2000 + index}"
                    ),
                    source_revision="1",
                    source_metadata={},
                    created_at=clock.now(),
                )
            )
        database.flush()
        database.add_all(
            [
                # Seen on both, more recently as a guest.
                DiscoverImpression(
                    user_id=guest_id,
                    source_video_id=sources[0],
                    seen_at=guest_seen,
                ),
                DiscoverImpression(
                    user_id=destination_id,
                    source_video_id=sources[0],
                    seen_at=account_seen,
                ),
                # Seen on both, more recently on the account.
                DiscoverImpression(
                    user_id=guest_id,
                    source_video_id=sources[1],
                    seen_at=account_seen,
                ),
                DiscoverImpression(
                    user_id=destination_id,
                    source_video_id=sources[1],
                    seen_at=guest_seen,
                ),
                # Seen only as a guest.
                DiscoverImpression(
                    user_id=guest_id,
                    source_video_id=sources[2],
                    seen_at=guest_seen,
                ),
            ]
        )

    with Session(engine) as database, database.begin():
        merged = merger.merge(
            database,
            guest_user_id=guest_id,
            apple_subject="impression-apple-subject",
            idempotency_key="impression-merge",
        )

    assert merged == destination_id
    with Session(engine) as database:
        carried = {
            row.source_video_id: row.seen_at
            for row in database.scalars(
                select(DiscoverImpression).where(
                    DiscoverImpression.user_id == destination_id
                )
            )
        }
        assert carried == {
            sources[0]: guest_seen,
            sources[1]: guest_seen,
            sources[2]: guest_seen,
        }
        assert (
            database.scalar(
                select(func.count())
                .select_from(DiscoverImpression)
                .where(DiscoverImpression.user_id == guest_id)
            )
            == 0
        )

    engine.dispose()
