import hashlib
import hmac
import secrets
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from uuid import UUID

import jwt


class AccessTokenInvalid(Exception):
    pass


class AccessTokenExpired(AccessTokenInvalid):
    pass


@dataclass(frozen=True)
class IssuedRefreshToken:
    value: str
    digest: bytes


class RefreshTokenCodec:
    def issue(self, session_id: UUID) -> IssuedRefreshToken:
        value = f"{session_id}.{secrets.token_urlsafe(48)}"
        return IssuedRefreshToken(value=value, digest=self.digest(value))

    def digest(self, value: str) -> bytes:
        return hashlib.sha256(value.encode("utf-8")).digest()

    def matches(self, value: str, expected_digest: bytes) -> bool:
        return hmac.compare_digest(self.digest(value), expected_digest)

    def session_id(self, value: str) -> UUID:
        identifier, separator, secret = value.partition(".")
        if not separator or not secret:
            raise ValueError("invalid refresh token")
        return UUID(identifier)


@dataclass(frozen=True)
class IssuedAccessToken:
    value: str
    expires_at: datetime


@dataclass(frozen=True)
class AccessClaims:
    user_id: UUID
    session_id: UUID
    device_id: UUID
    user_kind: str


class AccessTokenCodec:
    def __init__(
        self,
        *,
        signing_secret: str,
        issuer: str,
        lifetime: timedelta,
    ) -> None:
        self._signing_secret = signing_secret
        self._issuer = issuer
        self._lifetime = lifetime

    def issue(
        self,
        *,
        user_id: UUID,
        session_id: UUID,
        device_id: UUID,
        user_kind: str,
        now: datetime,
    ) -> IssuedAccessToken:
        expires_at = now + self._lifetime
        payload = {
            "sub": str(user_id),
            "sid": str(session_id),
            "did": str(device_id),
            "kind": user_kind,
            "iss": self._issuer,
            "iat": int(now.timestamp()),
            "exp": int(expires_at.timestamp()),
            "jti": secrets.token_hex(16),
        }
        return IssuedAccessToken(
            value=jwt.encode(payload, self._signing_secret, algorithm="HS256"),
            expires_at=expires_at,
        )

    def decode(self, value: str, *, now: datetime) -> AccessClaims:
        try:
            payload: dict[str, Any] = jwt.decode(
                value,
                self._signing_secret,
                algorithms=["HS256"],
                issuer=self._issuer,
                options={"verify_exp": False, "verify_iat": False},
            )
            expires_at = datetime.fromtimestamp(int(payload["exp"]), tz=UTC)
            if now >= expires_at:
                raise AccessTokenExpired
            return AccessClaims(
                user_id=UUID(str(payload["sub"])),
                session_id=UUID(str(payload["sid"])),
                device_id=UUID(str(payload["did"])),
                user_kind=str(payload["kind"]),
            )
        except AccessTokenExpired:
            raise
        except (jwt.PyJWTError, KeyError, TypeError, ValueError) as error:
            raise AccessTokenInvalid from error
