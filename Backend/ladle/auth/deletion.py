import hashlib
import hmac
from dataclasses import dataclass
from uuid import UUID, uuid4

from sqlalchemy import delete, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.orm import Session, sessionmaker

from ladle.auth.apple import AppleCredentials, AppleTokenRevocationFailed
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessClaims
from ladle.clock import Clock
from ladle.crypto.private_text import PrivateTextCipher
from ladle.db.models import (
    AccountDeletionAudit,
    AppleIdentity,
    ObjectDeletionQueue,
    Recipe,
    RecipeImage,
    User,
)


class AccountDeletionUnavailable(Exception):
    pass


@dataclass(frozen=True)
class AccountDeletionReceipt:
    deletion_id: UUID
    status: str


class AccountDeletionService:
    def __init__(
        self,
        *,
        session_factory: sessionmaker[Session],
        sessions: SessionService,
        clock: Clock,
        audit_secret: str,
        private_text: PrivateTextCipher,
        apple_credentials: AppleCredentials | None,
    ) -> None:
        self._database_sessions = session_factory
        self._sessions = sessions
        self._clock = clock
        self._audit_key = hashlib.sha256(audit_secret.encode("utf-8")).digest()
        self._private_text = private_text
        self._apple = apple_credentials

    def completed(
        self,
        *,
        user_id: UUID,
        idempotency_key: str,
    ) -> AccountDeletionReceipt | None:
        digest = self._idempotency_digest(user_id, idempotency_key)
        with self._database_sessions() as database:
            audit = database.scalar(
                select(AccountDeletionAudit).where(
                    AccountDeletionAudit.idempotency_digest == digest,
                    AccountDeletionAudit.status == "completed",
                )
            )
            return self._receipt(audit) if audit is not None else None

    def delete(
        self,
        *,
        claims: AccessClaims,
        refresh_token: str,
        idempotency_key: str,
    ) -> AccountDeletionReceipt:
        digest = self._idempotency_digest(claims.user_id, idempotency_key)
        encrypted_apple_token: bytes | None = None
        with self._database_sessions.begin() as database:
            self._sessions.reauthenticate(
                database,
                session_id=claims.session_id,
                device_id=claims.device_id,
                refresh_token=refresh_token,
            )
            user = database.get(User, claims.user_id)
            if user is None:
                raise AccountDeletionUnavailable
            audit = self._audit(
                database,
                digest=digest,
                user_id=user.id,
                account_kind=user.kind,
            )
            if audit.status == "completed":
                return self._receipt(audit)
            identity = database.scalar(
                select(AppleIdentity).where(AppleIdentity.user_id == user.id)
            )
            encrypted_apple_token = (
                identity.refresh_token_encrypted if identity is not None else None
            )
            audit.status = (
                "revokingProvider" if encrypted_apple_token is not None else "deleting"
            )
            audit.failure_code = None
            audit.updated_at = self._clock.now()

        if encrypted_apple_token is not None:
            if self._apple is None:
                self._mark_failed(digest, "appleCredentialsUnavailable")
                raise AccountDeletionUnavailable
            try:
                refresh = self._private_text.decrypt(encrypted_apple_token)
                self._apple.revoke(refresh)
            except (AppleTokenRevocationFailed, ValueError) as error:
                self._mark_failed(digest, type(error).__name__)
                raise AccountDeletionUnavailable from error

        with self._database_sessions.begin() as database:
            audit = database.execute(
                select(AccountDeletionAudit)
                .where(AccountDeletionAudit.idempotency_digest == digest)
                .with_for_update()
            ).scalar_one()
            user = database.get(User, claims.user_id)
            if user is None:
                audit.status = "completed"
                audit.completed_at = self._clock.now()
                audit.updated_at = self._clock.now()
                return self._receipt(audit)
            audit.status = "deleting"
            audit.updated_at = self._clock.now()
            self._queue_owned_objects(database, user.id)
            database.execute(delete(User).where(User.merged_into_user_id == user.id))
            database.delete(user)
            audit.status = "completed"
            audit.completed_at = self._clock.now()
            audit.updated_at = self._clock.now()
            return self._receipt(audit)

    def _audit(
        self,
        database: Session,
        *,
        digest: bytes,
        user_id: UUID,
        account_kind: str,
    ) -> AccountDeletionAudit:
        audit = database.scalar(
            select(AccountDeletionAudit).where(
                AccountDeletionAudit.idempotency_digest == digest
            )
        )
        if audit is not None:
            return audit
        now = self._clock.now()
        audit = AccountDeletionAudit(
            id=uuid4(),
            user_digest=self._digest(str(user_id)),
            idempotency_digest=digest,
            account_kind=account_kind,
            status="requested",
            created_at=now,
            updated_at=now,
        )
        database.add(audit)
        database.flush()
        return audit

    def _mark_failed(self, digest: bytes, failure_code: str) -> None:
        with self._database_sessions.begin() as database:
            audit = database.scalar(
                select(AccountDeletionAudit).where(
                    AccountDeletionAudit.idempotency_digest == digest
                )
            )
            if audit is not None:
                audit.status = "failed"
                audit.failure_code = failure_code[:128]
                audit.updated_at = self._clock.now()

    def _queue_owned_objects(self, database: Session, user_id: UUID) -> None:
        keys = database.scalars(
            select(RecipeImage.object_key)
            .join(Recipe, Recipe.id == RecipeImage.recipe_id)
            .where(
                Recipe.user_id == user_id,
                RecipeImage.object_key.is_not(None),
            )
        )
        now = self._clock.now()
        for key in keys:
            if key is not None:
                database.execute(
                    insert(ObjectDeletionQueue)
                    .values(
                        object_key=key,
                        reason="accountDeletion",
                        available_at=now,
                        created_at=now,
                    )
                    .on_conflict_do_nothing(
                        index_elements=[ObjectDeletionQueue.object_key]
                    )
                )

    def _idempotency_digest(self, user_id: UUID, idempotency_key: str) -> bytes:
        return self._digest(f"{user_id}:{idempotency_key}")

    def _digest(self, value: str) -> bytes:
        return hmac.digest(self._audit_key, value.encode("utf-8"), "sha256")

    @staticmethod
    def _receipt(audit: AccountDeletionAudit) -> AccountDeletionReceipt:
        return AccountDeletionReceipt(
            deletion_id=audit.id,
            status=audit.status,
        )
