from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID, uuid4

from sqlalchemy import select, update
from sqlalchemy.orm import Session

from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.clock import Clock
from ladle.db.models import AuthSession, User


class RefreshTokenInvalid(Exception):
    pass


class RefreshTokenExpired(RefreshTokenInvalid):
    pass


class RefreshTokenRevoked(RefreshTokenInvalid):
    pass


class RefreshTokenReuseDetected(RefreshTokenInvalid):
    pass


@dataclass(frozen=True)
class SessionTokens:
    access_token: str
    access_expires_at: datetime
    refresh_token: str | None
    user_id: UUID
    device_id: UUID
    user_kind: str


class SessionService:
    def __init__(
        self,
        *,
        access_tokens: AccessTokenCodec,
        refresh_tokens: RefreshTokenCodec,
        refresh_lifetime: timedelta,
        rotation_grace: timedelta,
        clock: Clock,
    ) -> None:
        self._access_tokens = access_tokens
        self._refresh_tokens = refresh_tokens
        self._refresh_lifetime = refresh_lifetime
        self._rotation_grace = rotation_grace
        self._clock = clock

    def create(
        self,
        database: Session,
        *,
        user_id: UUID,
        device_id: UUID,
    ) -> SessionTokens:
        now = self._clock.now()
        user = database.get(User, user_id)
        if user is None:
            raise ValueError("user does not exist")
        session_id = uuid4()
        refresh = self._refresh_tokens.issue(session_id)
        stored = AuthSession(
            id=session_id,
            user_id=user_id,
            device_id=device_id,
            token_family_id=uuid4(),
            refresh_token_hash=refresh.digest,
            expires_at=now + self._refresh_lifetime,
            created_at=now,
        )
        database.add(stored)
        return self._tokens(
            stored=stored,
            user_kind=user.kind,
            refresh_token=refresh.value,
            now=now,
        )

    def refresh(
        self,
        database: Session,
        *,
        refresh_token: str | None,
        device_id: UUID,
    ) -> SessionTokens:
        if refresh_token is None:
            raise RefreshTokenInvalid
        try:
            session_id = self._refresh_tokens.session_id(refresh_token)
        except ValueError as error:
            raise RefreshTokenInvalid from error

        stored = database.execute(
            select(AuthSession).where(AuthSession.id == session_id).with_for_update()
        ).scalar_one_or_none()
        if stored is None:
            raise RefreshTokenInvalid

        now = self._clock.now()
        if stored.revoked_at is not None:
            raise RefreshTokenRevoked
        if now >= stored.expires_at:
            raise RefreshTokenExpired

        user = database.get(User, stored.user_id)
        if user is None:
            raise RefreshTokenInvalid

        current_matches = self._refresh_tokens.matches(
            refresh_token, stored.refresh_token_hash
        )
        previous_matches = (
            stored.previous_refresh_token_hash is not None
            and self._refresh_tokens.matches(
                refresh_token, stored.previous_refresh_token_hash
            )
        )

        if current_matches and device_id == stored.device_id:
            rotated = self._refresh_tokens.issue(stored.id)
            stored.previous_refresh_token_hash = stored.refresh_token_hash
            stored.previous_valid_until = now + self._rotation_grace
            stored.refresh_token_hash = rotated.digest
            stored.rotated_at = now
            return self._tokens(
                stored=stored,
                user_kind=user.kind,
                refresh_token=rotated.value,
                now=now,
            )

        inside_grace = (
            previous_matches
            and stored.previous_valid_until is not None
            and now <= stored.previous_valid_until
            and device_id == stored.device_id
        )
        if inside_grace:
            return self._tokens(
                stored=stored,
                user_kind=user.kind,
                refresh_token=None,
                now=now,
            )

        if previous_matches or current_matches:
            self._revoke_family(database, stored.token_family_id, now)
            raise RefreshTokenReuseDetected
        raise RefreshTokenInvalid

    def revoke(self, database: Session, *, session_id: UUID) -> None:
        stored = database.execute(
            select(AuthSession).where(AuthSession.id == session_id).with_for_update()
        ).scalar_one_or_none()
        if stored is not None and stored.revoked_at is None:
            stored.revoked_at = self._clock.now()

    def _revoke_family(
        self,
        database: Session,
        token_family_id: UUID,
        now: datetime,
    ) -> None:
        database.execute(
            update(AuthSession)
            .where(
                AuthSession.token_family_id == token_family_id,
                AuthSession.revoked_at.is_(None),
            )
            .values(revoked_at=now)
        )

    def _tokens(
        self,
        *,
        stored: AuthSession,
        user_kind: str,
        refresh_token: str | None,
        now: datetime,
    ) -> SessionTokens:
        access = self._access_tokens.issue(
            user_id=stored.user_id,
            session_id=stored.id,
            device_id=stored.device_id,
            user_kind=user_kind,
            now=now,
        )
        return SessionTokens(
            access_token=access.value,
            access_expires_at=access.expires_at,
            refresh_token=refresh_token,
            user_id=stored.user_id,
            device_id=stored.device_id,
            user_kind=user_kind,
        )
