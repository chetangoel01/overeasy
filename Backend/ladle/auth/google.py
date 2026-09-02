from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import timedelta
from typing import Any, Protocol, cast

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from jwt.algorithms import RSAAlgorithm

from ladle.clock import Clock

GOOGLE_ISSUERS = {"accounts.google.com", "https://accounts.google.com"}


class GoogleIdentityTokenInvalid(Exception):
    pass


def _optional_text(value: object, *, limit: int) -> str | None:
    """A profile claim, or `None` if it is absent, blank or not a string.

    A claim is provider-controlled input even after the signature checks out,
    so it is bounded here rather than at the column.
    """
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    if not trimmed:
        return None
    return trimmed[:limit]


@dataclass(frozen=True)
class GoogleIdentityClaims:
    subject: str
    # Profile claims. Optional by contract as well as in practice: they depend
    # on the scopes granted, and a missing name is a cook without a default
    # display name, not a failed sign-in.
    name: str | None = None
    picture: str | None = None


@dataclass(frozen=True)
class GoogleCredential:
    subject: str
    name: str | None = None
    picture: str | None = None


class GoogleJWKS(Protocol):
    def fetch(self) -> Mapping[str, object]: ...


class GoogleCredentials(Protocol):
    def verify(self, identity_token: str) -> GoogleCredential: ...


class HTTPGoogleJWKS:
    def __init__(self, *, http: httpx.Client, url: str) -> None:
        self._http = http
        self._url = url

    def fetch(self) -> Mapping[str, object]:
        try:
            response = self._http.get(self._url)
            response.raise_for_status()
            value = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise GoogleIdentityTokenInvalid("Google JWKS is unavailable") from error
        if not isinstance(value, dict):
            raise GoogleIdentityTokenInvalid("Google JWKS response is malformed")
        return value


class GoogleIdentityTokenVerifier:
    def __init__(
        self,
        *,
        jwks: GoogleJWKS,
        audience: str,
        clock: Clock,
        maximum_age: timedelta,
        clock_skew: timedelta,
    ) -> None:
        self._jwks = jwks
        self._audience = audience
        self._clock = clock
        self._maximum_age = maximum_age
        self._clock_skew = clock_skew
        self._cached_keys: dict[str, Mapping[str, object]] | None = None

    def verify(self, identity_token: str) -> GoogleIdentityClaims:
        try:
            header = jwt.get_unverified_header(identity_token)
            key_id = str(header["kid"])
            if header.get("alg") != "RS256":
                raise GoogleIdentityTokenInvalid(
                    "Google identity token algorithm is invalid"
                )
        except (jwt.PyJWTError, KeyError, TypeError, ValueError) as error:
            raise GoogleIdentityTokenInvalid(
                "Google identity token header is invalid"
            ) from error

        key = self._key(key_id, refresh=False)
        if key is None:
            key = self._key(key_id, refresh=True)
        if key is None:
            raise GoogleIdentityTokenInvalid("Google signing key is unknown")

        try:
            payload = self._decode(identity_token, key)
        except jwt.InvalidSignatureError:
            refreshed = self._key(key_id, refresh=True)
            if refreshed is None:
                raise GoogleIdentityTokenInvalid(
                    "Google token signature is invalid"
                ) from None
            try:
                payload = self._decode(identity_token, refreshed)
            except jwt.PyJWTError as error:
                raise GoogleIdentityTokenInvalid(
                    "Google identity token is invalid"
                ) from error
        except jwt.PyJWTError as error:
            raise GoogleIdentityTokenInvalid(
                "Google identity token is invalid"
            ) from error

        try:
            issuer = str(payload["iss"])
            subject = str(payload["sub"])
            issued_at = int(payload["iat"])
            expires_at = int(payload["exp"])
        except (KeyError, TypeError, ValueError) as error:
            raise GoogleIdentityTokenInvalid(
                "Google identity token claims are invalid"
            ) from error
        if issuer not in GOOGLE_ISSUERS:
            raise GoogleIdentityTokenInvalid("Google identity token issuer is invalid")
        if not subject:
            raise GoogleIdentityTokenInvalid("Google subject is empty")

        now = int(self._clock.now().timestamp())
        skew = int(self._clock_skew.total_seconds())
        maximum_age = int(self._maximum_age.total_seconds())
        if expires_at < now - skew:
            raise GoogleIdentityTokenInvalid("Google identity token expired")
        if issued_at > now + skew or issued_at < now - maximum_age - skew:
            raise GoogleIdentityTokenInvalid(
                "Google identity token issued-at is invalid"
            )
        return GoogleIdentityClaims(
            subject=subject,
            name=_optional_text(payload.get("name"), limit=64),
            picture=_optional_text(payload.get("picture"), limit=2048),
        )

    def _decode(
        self,
        identity_token: str,
        key: Mapping[str, object],
    ) -> dict[str, Any]:
        public_key = cast(RSAPublicKey, RSAAlgorithm.from_jwk(dict(key)))
        return jwt.decode(
            identity_token,
            public_key,
            algorithms=["RS256"],
            audience=self._audience,
            options={
                "verify_exp": False,
                "verify_iat": False,
                "verify_iss": False,
                "require": ["iss", "aud", "sub", "iat", "exp"],
            },
        )

    def _key(
        self,
        key_id: str,
        *,
        refresh: bool,
    ) -> Mapping[str, object] | None:
        if self._cached_keys is None or refresh:
            response = self._jwks.fetch()
            raw_keys = response.get("keys")
            if not isinstance(raw_keys, Sequence) or isinstance(raw_keys, str):
                raise GoogleIdentityTokenInvalid("Google JWKS keys are malformed")
            keys: dict[str, Mapping[str, object]] = {}
            for value in raw_keys:
                if isinstance(value, Mapping) and isinstance(value.get("kid"), str):
                    keys[str(value["kid"])] = value
            self._cached_keys = keys
        return self._cached_keys.get(key_id)


class GoogleCredentialService:
    def __init__(self, identity_tokens: GoogleIdentityTokenVerifier) -> None:
        self._identity_tokens = identity_tokens

    def verify(self, identity_token: str) -> GoogleCredential:
        claims = self._identity_tokens.verify(identity_token)
        return GoogleCredential(
            subject=claims.subject,
            name=claims.name,
            picture=claims.picture,
        )
