import hashlib
import hmac
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import timedelta
from typing import Any, Protocol, cast

import httpx
import jwt
from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicKey
from jwt.algorithms import RSAAlgorithm

from ladle.clock import Clock

APPLE_ISSUER = "https://appleid.apple.com"


class AppleIdentityTokenInvalid(Exception):
    pass


class AppleAuthorizationCodeInvalid(Exception):
    pass


class AppleTokenRevocationFailed(Exception):
    pass


@dataclass(frozen=True)
class AppleIdentityClaims:
    subject: str


@dataclass(frozen=True)
class AppleCredential:
    subject: str
    refresh_token: str | None = None


class AppleJWKS(Protocol):
    def fetch(self) -> Mapping[str, object]: ...


class AppleAuthorizationCodes(Protocol):
    def exchange(self, authorization_code: str) -> str | None: ...

    def revoke(self, refresh_token: str) -> None: ...


class AppleCredentials(Protocol):
    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential: ...

    def revoke(self, refresh_token: str) -> None: ...


class HTTPAppleJWKS:
    def __init__(self, *, http: httpx.Client, url: str) -> None:
        self._http = http
        self._url = url

    def fetch(self) -> Mapping[str, object]:
        try:
            response = self._http.get(self._url)
            response.raise_for_status()
            value = response.json()
        except (httpx.HTTPError, ValueError) as error:
            raise AppleIdentityTokenInvalid("Apple JWKS is unavailable") from error
        if not isinstance(value, dict):
            raise AppleIdentityTokenInvalid("Apple JWKS response is malformed")
        return value


class AppleIdentityTokenVerifier:
    def __init__(
        self,
        *,
        jwks: AppleJWKS,
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

    def verify(self, identity_token: str, *, nonce: str) -> AppleIdentityClaims:
        try:
            header = jwt.get_unverified_header(identity_token)
            key_id = str(header["kid"])
            if header.get("alg") != "RS256":
                raise AppleIdentityTokenInvalid(
                    "Apple identity token algorithm is invalid"
                )
        except (jwt.PyJWTError, KeyError, TypeError, ValueError) as error:
            raise AppleIdentityTokenInvalid(
                "Apple identity token header is invalid"
            ) from error

        key = self._key(key_id, refresh=False)
        if key is None:
            key = self._key(key_id, refresh=True)
        if key is None:
            raise AppleIdentityTokenInvalid("Apple signing key is unknown")

        try:
            payload = self._decode(identity_token, key)
        except jwt.InvalidSignatureError:
            refreshed = self._key(key_id, refresh=True)
            if refreshed is None:
                raise AppleIdentityTokenInvalid(
                    "Apple token signature is invalid"
                ) from None
            try:
                payload = self._decode(identity_token, refreshed)
            except jwt.PyJWTError as error:
                raise AppleIdentityTokenInvalid(
                    "Apple identity token is invalid"
                ) from error
        except jwt.PyJWTError as error:
            raise AppleIdentityTokenInvalid(
                "Apple identity token is invalid"
            ) from error

        try:
            subject = str(payload["sub"])
            issued_at = int(payload["iat"])
            expires_at = int(payload["exp"])
            token_nonce = str(payload["nonce"])
        except (KeyError, TypeError, ValueError) as error:
            raise AppleIdentityTokenInvalid(
                "Apple identity token claims are invalid"
            ) from error
        if not subject:
            raise AppleIdentityTokenInvalid("Apple subject is empty")

        now = int(self._clock.now().timestamp())
        skew = int(self._clock_skew.total_seconds())
        maximum_age = int(self._maximum_age.total_seconds())
        if expires_at < now - skew:
            raise AppleIdentityTokenInvalid("Apple identity token expired")
        if issued_at > now + skew or issued_at < now - maximum_age - skew:
            raise AppleIdentityTokenInvalid("Apple identity token issued-at is invalid")
        expected_nonce = hashlib.sha256(nonce.encode("utf-8")).hexdigest()
        if not hmac.compare_digest(token_nonce, expected_nonce):
            raise AppleIdentityTokenInvalid("Apple identity token nonce is invalid")
        return AppleIdentityClaims(subject=subject)

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
            issuer=APPLE_ISSUER,
            options={
                "verify_exp": False,
                "verify_iat": False,
                "require": ["iss", "aud", "sub", "iat", "exp", "nonce"],
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
                raise AppleIdentityTokenInvalid("Apple JWKS keys are malformed")
            keys: dict[str, Mapping[str, object]] = {}
            for value in raw_keys:
                if isinstance(value, Mapping) and isinstance(value.get("kid"), str):
                    keys[str(value["kid"])] = value
            self._cached_keys = keys
        return self._cached_keys.get(key_id)


class AppleAuthorizationCodeClient:
    def __init__(
        self,
        *,
        http: httpx.Client,
        team_id: str,
        key_id: str,
        private_key: str,
        client_id: str,
        token_url: str,
        clock: Clock,
    ) -> None:
        self._http = http
        self._team_id = team_id
        self._key_id = key_id
        self._private_key = private_key
        self._client_id = client_id
        self._token_url = token_url
        self._clock = clock

    def exchange(self, authorization_code: str) -> str | None:
        response = self._post(
            {
                "client_id": self._client_id,
                "client_secret": self._client_secret(),
                "code": authorization_code,
                "grant_type": "authorization_code",
            },
            error_type=AppleAuthorizationCodeInvalid,
        )
        try:
            payload = response.json()
        except ValueError as error:
            raise AppleAuthorizationCodeInvalid(
                "Apple token response is malformed"
            ) from error
        if not isinstance(payload, dict) or not payload.get("access_token"):
            raise AppleAuthorizationCodeInvalid("Apple token response is incomplete")
        refresh_token = payload.get("refresh_token")
        return str(refresh_token) if refresh_token else None

    def revoke(self, refresh_token: str) -> None:
        self._post(
            {
                "client_id": self._client_id,
                "client_secret": self._client_secret(),
                "token": refresh_token,
                "token_type_hint": "refresh_token",
            },
            error_type=AppleTokenRevocationFailed,
        )

    def _client_secret(self) -> str:
        now = self._clock.now()
        return jwt.encode(
            {
                "iss": self._team_id,
                "iat": int(now.timestamp()),
                "exp": int((now + timedelta(days=180)).timestamp()),
                "aud": APPLE_ISSUER,
                "sub": self._client_id,
            },
            self._private_key,
            algorithm="ES256",
            headers={"kid": self._key_id},
        )

    def _post(
        self,
        data: dict[str, str],
        *,
        error_type: type[Exception],
    ) -> httpx.Response:
        try:
            response = self._http.post(
                self._token_url,
                data=data,
            )
        except httpx.HTTPError as error:
            raise error_type("Apple token service is unavailable") from error
        if response.status_code != 200:
            raise error_type("Apple token request was rejected")
        return response


class AppleCredentialService:
    def __init__(
        self,
        *,
        identity_tokens: AppleIdentityTokenVerifier,
        authorization_codes: AppleAuthorizationCodes,
    ) -> None:
        self._identity_tokens = identity_tokens
        self._authorization_codes = authorization_codes

    def verify(
        self,
        *,
        identity_token: str,
        authorization_code: str,
        nonce: str,
    ) -> AppleCredential:
        claims = self._identity_tokens.verify(identity_token, nonce=nonce)
        refresh_token = self._authorization_codes.exchange(authorization_code)
        return AppleCredential(
            subject=claims.subject,
            refresh_token=refresh_token,
        )

    def revoke(self, refresh_token: str) -> None:
        self._authorization_codes.revoke(refresh_token)
