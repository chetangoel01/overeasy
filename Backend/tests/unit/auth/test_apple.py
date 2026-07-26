import hashlib
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from urllib.parse import parse_qs

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from jwt.algorithms import RSAAlgorithm

from ladle.auth.apple import (
    AppleAuthorizationCodeClient,
    AppleIdentityTokenInvalid,
    AppleIdentityTokenVerifier,
)


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@dataclass
class RotatingJWKS:
    responses: list[dict[str, object]]
    calls: int = 0

    def fetch(self) -> dict[str, object]:
        response = self.responses[min(self.calls, len(self.responses) - 1)]
        self.calls += 1
        return response


def rsa_key(kid: str) -> tuple[rsa.RSAPrivateKey, dict[str, object]]:
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    public = RSAAlgorithm.to_jwk(private.public_key(), as_dict=True)
    public.update({"kid": kid, "alg": "RS256", "use": "sig"})
    return private, public


def identity_token(
    private: rsa.RSAPrivateKey,
    *,
    kid: str,
    now: datetime,
    nonce: str,
    issuer: str = "https://appleid.apple.com",
    audience: str = "com.ladle.test",
    issued_at: datetime | None = None,
    expires_at: datetime | None = None,
) -> str:
    return jwt.encode(
        {
            "iss": issuer,
            "aud": audience,
            "sub": "apple-stable-subject",
            "iat": int((issued_at or now).timestamp()),
            "exp": int((expires_at or now + timedelta(minutes=5)).timestamp()),
            "nonce": hashlib.sha256(nonce.encode()).hexdigest(),
        },
        private,
        algorithm="RS256",
        headers={"kid": kid},
    )


def test_identity_token_refetches_rotated_jwks_and_validates_nonce() -> None:
    now = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
    _, old_jwk = rsa_key("old")
    current_private, current_jwk = rsa_key("current")
    jwks = RotatingJWKS(
        responses=[
            {"keys": [old_jwk]},
            {"keys": [current_jwk]},
        ]
    )
    verifier = AppleIdentityTokenVerifier(
        jwks=jwks,
        audience="com.ladle.test",
        clock=FrozenClock(now),
        maximum_age=timedelta(minutes=10),
        clock_skew=timedelta(seconds=30),
    )

    claims = verifier.verify(
        identity_token(
            current_private,
            kid="current",
            now=now,
            nonce="raw-nonce",
        ),
        nonce="raw-nonce",
    )

    assert claims.subject == "apple-stable-subject"
    assert jwks.calls == 2


@pytest.mark.parametrize(
    ("token_overrides", "nonce"),
    [
        ({"issuer": "https://attacker.example"}, "raw-nonce"),
        ({"audience": "com.someone.else"}, "raw-nonce"),
        ({"expires_at": datetime(2026, 7, 23, 20, 59, tzinfo=UTC)}, "raw-nonce"),
        ({"issued_at": datetime(2026, 7, 23, 21, 1, tzinfo=UTC)}, "raw-nonce"),
        ({"issued_at": datetime(2026, 7, 23, 20, 30, tzinfo=UTC)}, "raw-nonce"),
        ({}, "different-nonce"),
    ],
)
def test_identity_token_rejects_invalid_claims(
    token_overrides: dict[str, object],
    nonce: str,
) -> None:
    now = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
    private, jwk = rsa_key("current")
    verifier = AppleIdentityTokenVerifier(
        jwks=RotatingJWKS([{"keys": [jwk]}]),
        audience="com.ladle.test",
        clock=FrozenClock(now),
        maximum_age=timedelta(minutes=10),
        clock_skew=timedelta(seconds=30),
    )

    with pytest.raises(AppleIdentityTokenInvalid):
        verifier.verify(
            identity_token(
                private,
                kid="current",
                now=now,
                nonce="raw-nonce",
                **token_overrides,
            ),
            nonce=nonce,
        )


def test_authorization_code_exchange_signs_apple_client_secret() -> None:
    now = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
    private = ec.generate_private_key(ec.SECP256R1())
    private_pem = private.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()
    requests: list[httpx.Request] = []

    def exchange(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "access_token": "apple-access",
                "token_type": "Bearer",
                "expires_in": 3600,
                "refresh_token": "apple-refresh",
                "id_token": "apple-id-token",
            },
        )

    client = AppleAuthorizationCodeClient(
        http=httpx.Client(transport=httpx.MockTransport(exchange)),
        team_id="TEAMID1234",
        key_id="KEYID12345",
        private_key=private_pem,
        client_id="com.ladle.test",
        token_url="https://appleid.apple.com/auth/token",
        clock=FrozenClock(now),
    )

    refresh_token = client.exchange("one-time-code")
    client.revoke("apple-refresh")

    assert refresh_token == "apple-refresh"
    assert len(requests) == 2
    form = parse_qs(requests[0].content.decode())
    assert form["client_id"] == ["com.ladle.test"]
    assert form["code"] == ["one-time-code"]
    assert form["grant_type"] == ["authorization_code"]
    secret = form["client_secret"][0]
    header = jwt.get_unverified_header(secret)
    claims = jwt.decode(
        secret,
        private.public_key(),
        algorithms=["ES256"],
        audience="https://appleid.apple.com",
    )
    assert header["kid"] == "KEYID12345"
    assert claims["iss"] == "TEAMID1234"
    assert claims["sub"] == "com.ladle.test"
    assert claims["iat"] == int(now.timestamp())
    assert claims["exp"] <= int((now + timedelta(days=180)).timestamp())

    revoke_form = parse_qs(requests[1].content.decode())
    assert revoke_form["client_id"] == ["com.ladle.test"]
    assert revoke_form["token"] == ["apple-refresh"]
    assert revoke_form["token_type_hint"] == ["refresh_token"]
