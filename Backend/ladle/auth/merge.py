import hashlib
from uuid import UUID

from sqlalchemy import exists, func, select, update
from sqlalchemy.orm import Session

from ladle.clock import Clock
from ladle.db.models import (
    AppleIdentity,
    AuthSession,
    Device,
    GoogleIdentity,
    ImportJob,
    ImportQuotaEvent,
    Recipe,
    RecipeChange,
    RecipeSlotReservation,
    User,
)
from ladle.sync.sequence import allocate_sequence


class AccountMergeInvalid(Exception):
    pass


class AccountMergeService:
    def __init__(self, *, clock: Clock) -> None:
        self._clock = clock

    def merge(
        self,
        database: Session,
        *,
        guest_user_id: UUID,
        apple_subject: str,
        idempotency_key: str,
        apple_refresh_token_encrypted: bytes | None = None,
    ) -> UUID:
        if not apple_subject or not idempotency_key:
            raise AccountMergeInvalid
        self._lock_apple_subject(database, apple_subject)
        identity = database.get(AppleIdentity, apple_subject)
        if identity is None:
            return self._claim_identity(
                database,
                guest_user_id=guest_user_id,
                kind="apple",
                identity=AppleIdentity(
                    apple_sub=apple_subject,
                    user_id=guest_user_id,
                    refresh_token_encrypted=apple_refresh_token_encrypted,
                    created_at=self._clock.now(),
                ),
            )

        if apple_refresh_token_encrypted is not None:
            identity.refresh_token_encrypted = apple_refresh_token_encrypted
        return self._merge_users(
            database,
            source_id=guest_user_id,
            destination_id=identity.user_id,
            kind="apple",
        )

    def merge_google(
        self,
        database: Session,
        *,
        guest_user_id: UUID,
        google_subject: str,
        idempotency_key: str,
    ) -> UUID:
        if not google_subject or not idempotency_key:
            raise AccountMergeInvalid
        self._lock_google_subject(database, google_subject)
        identity = database.get(GoogleIdentity, google_subject)
        if identity is None:
            return self._claim_identity(
                database,
                guest_user_id=guest_user_id,
                kind="google",
                identity=GoogleIdentity(
                    google_sub=google_subject,
                    user_id=guest_user_id,
                    created_at=self._clock.now(),
                ),
            )
        return self._merge_users(
            database,
            source_id=guest_user_id,
            destination_id=identity.user_id,
            kind="google",
        )

    def _claim_identity(
        self,
        database: Session,
        *,
        guest_user_id: UUID,
        kind: str,
        identity: AppleIdentity | GoogleIdentity,
    ) -> UUID:
        guest = self._lock_users(database, [guest_user_id])[guest_user_id]
        if guest.merged_into_user_id is not None:
            raise AccountMergeInvalid
        if guest.kind not in {"guest", kind}:
            raise AccountMergeInvalid
        # One provider identity per account: a second Apple or Google ID on
        # the same user would leave a grant that account deletion never
        # revokes, since deletion looks up a single identity row. The user
        # row is locked above, so concurrent claims serialize here; the
        # unique constraint on user_id is the schema-level backstop.
        claimed = database.scalar(
            select(AppleIdentity.apple_sub).where(AppleIdentity.user_id == guest.id)
            if isinstance(identity, AppleIdentity)
            else select(GoogleIdentity.google_sub).where(
                GoogleIdentity.user_id == guest.id
            )
        )
        if claimed is not None:
            raise AccountMergeInvalid
        guest.kind = kind
        database.add(identity)
        self._revoke_sessions(database, guest.id)
        database.flush()
        return guest.id

    def _merge_users(
        self,
        database: Session,
        *,
        source_id: UUID,
        destination_id: UUID,
        kind: str,
    ) -> UUID:
        users = self._lock_users(
            database,
            sorted({source_id, destination_id}),
        )
        source = users[source_id]
        destination = users[destination_id]
        if source.id == destination.id:
            if source.kind != kind:
                source.kind = kind
            self._revoke_sessions(database, source.id)
            return source.id
        if source.merged_into_user_id is not None:
            if source.merged_into_user_id != destination.id:
                raise AccountMergeInvalid
            return destination.id
        if source.kind != "guest" or destination.kind != kind:
            raise AccountMergeInvalid

        now = self._clock.now()
        visible_recipes = list(
            database.scalars(
                select(Recipe)
                .where(
                    Recipe.user_id == source.id,
                    ~exists(
                        select(ImportJob.id).where(
                            ImportJob.candidate_recipe_id == Recipe.id
                        )
                    ),
                )
                .order_by(Recipe.created_at, Recipe.id)
            )
        )
        database.execute(
            update(Recipe)
            .where(Recipe.user_id == source.id)
            .values(user_id=destination.id)
        )
        database.execute(
            update(ImportJob)
            .where(ImportJob.user_id == source.id)
            .values(user_id=destination.id)
        )
        database.execute(
            update(ImportQuotaEvent)
            .where(ImportQuotaEvent.user_id == source.id)
            .values(user_id=destination.id)
        )
        database.execute(
            update(RecipeSlotReservation)
            .where(RecipeSlotReservation.user_id == source.id)
            .values(user_id=destination.id)
        )
        database.execute(
            update(Device)
            .where(Device.user_id == source.id)
            .values(user_id=destination.id)
        )
        self._revoke_sessions(database, source.id)
        for recipe in visible_recipes:
            database.add(
                RecipeChange(
                    user_id=destination.id,
                    sequence=allocate_sequence(database, destination.id),
                    recipe_id=recipe.id,
                    kind="delete" if recipe.deleted_at is not None else "upsert",
                    recipe_revision=recipe.revision,
                    changed_at=now,
                )
            )
        source.merged_into_user_id = destination.id
        database.flush()
        return destination.id

    def _lock_apple_subject(self, database: Session, apple_subject: str) -> None:
        digest = hashlib.sha256(apple_subject.encode("utf-8")).digest()
        lock_key = int.from_bytes(digest[:8], byteorder="big", signed=True)
        database.execute(select(func.pg_advisory_xact_lock(lock_key)))

    def _lock_google_subject(self, database: Session, google_subject: str) -> None:
        digest = hashlib.sha256(f"google:{google_subject}".encode()).digest()
        lock_key = int.from_bytes(digest[:8], byteorder="big", signed=True)
        database.execute(select(func.pg_advisory_xact_lock(lock_key)))

    def _lock_users(
        self,
        database: Session,
        user_ids: list[UUID],
    ) -> dict[UUID, User]:
        users = list(
            database.scalars(
                select(User)
                .where(User.id.in_(sorted(user_ids)))
                .order_by(User.id)
                .with_for_update()
            )
        )
        mapped = {user.id: user for user in users}
        if set(mapped) != set(user_ids):
            raise AccountMergeInvalid
        return mapped

    def _revoke_sessions(
        self,
        database: Session,
        user_id: UUID,
    ) -> None:
        database.execute(
            update(AuthSession)
            .where(
                AuthSession.user_id == user_id,
                AuthSession.revoked_at.is_(None),
            )
            .values(revoked_at=self._clock.now())
        )
