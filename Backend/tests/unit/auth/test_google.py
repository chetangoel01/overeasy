from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa
from jwt.algorithms import RSAAlgorithm

from ladle.auth.google import (
    GoogleIdentityTokenInvalid,
    GoogleIdentityTokenVerifier,
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
    issuer: str = "https://accounts.google.com",
    audience: str = "overeasy-server-client",
    issued_at: datetime | None = None,
    expires_at: datetime | None = None,
    profile: dict[str, object] | None = None,
) -> str:
    return jwt.encode(
        {
            "iss": issuer,
            "aud": audience,
            "sub": "google-stable-subject",
            "iat": int((issued_at or now).timestamp()),
            "exp": int((expires_at or now + timedelta(minutes=5)).timestamp()),
            "email_verified": True,
            **(profile or {}),
        },
        private,
        algorithm="RS256",
        headers={"kid": kid},
    )


def test_identity_token_refetches_rotated_jwks_and_returns_stable_subject() -> None:
    now = datetime(2026, 7, 26, 18, 0, tzinfo=UTC)
    _, old_jwk = rsa_key("old")
    current_private, current_jwk = rsa_key("current")
    jwks = RotatingJWKS(
        responses=[
            {"keys": [old_jwk]},
            {"keys": [current_jwk]},
        ]
    )
    verifier = GoogleIdentityTokenVerifier(
        jwks=jwks,
        audience="overeasy-server-client",
        clock=FrozenClock(now),
        maximum_age=timedelta(minutes=10),
        clock_skew=timedelta(seconds=30),
    )

    claims = verifier.verify(identity_token(current_private, kid="current", now=now))

    assert claims.subject == "google-stable-subject"
    assert jwks.calls == 2


@pytest.mark.parametrize(
    "token_overrides",
    [
        {"issuer": "https://attacker.example"},
        {"audience": "someone-elses-client"},
        {"expires_at": datetime(2026, 7, 26, 17, 59, tzinfo=UTC)},
        {"issued_at": datetime(2026, 7, 26, 18, 1, tzinfo=UTC)},
        {"issued_at": datetime(2026, 7, 26, 17, 30, tzinfo=UTC)},
    ],
)
def test_identity_token_rejects_invalid_claims(
    token_overrides: dict[str, object],
) -> None:
    now = datetime(2026, 7, 26, 18, 0, tzinfo=UTC)
    private, jwk = rsa_key("current")
    verifier = GoogleIdentityTokenVerifier(
        jwks=RotatingJWKS([{"keys": [jwk]}]),
        audience="overeasy-server-client",
        clock=FrozenClock(now),
        maximum_age=timedelta(minutes=10),
        clock_skew=timedelta(seconds=30),
    )

    with pytest.raises(GoogleIdentityTokenInvalid):
        verifier.verify(
            identity_token(
                private,
                kid="current",
                now=now,
                **token_overrides,
            )
        )


def _verifier(
    private_kid_jwk: dict[str, object],
    now: datetime,
) -> GoogleIdentityTokenVerifier:
    return GoogleIdentityTokenVerifier(
        jwks=RotatingJWKS(responses=[{"keys": [private_kid_jwk]}]),
        audience="overeasy-server-client",
        clock=FrozenClock(now),
        maximum_age=timedelta(minutes=10),
        clock_skew=timedelta(seconds=30),
    )


def test_profile_claims_are_read_from_the_verified_payload() -> None:
    now = datetime(2026, 9, 1, 18, 0, tzinfo=UTC)
    private, jwk = rsa_key("current")

    claims = _verifier(jwk, now).verify(
        identity_token(
            private,
            kid="current",
            now=now,
            profile={
                "name": "  Priya Raman  ",
                "picture": "https://lh3.example/a/photo.jpg",
            },
        )
    )

    # Trimmed, and taken from the payload whose signature was just checked
    # rather than from anything the client sent alongside it.
    assert claims.name == "Priya Raman"
    assert claims.picture == "https://lh3.example/a/photo.jpg"


def test_absent_or_blank_profile_claims_are_none_rather_than_empty() -> None:
    now = datetime(2026, 9, 1, 18, 0, tzinfo=UTC)
    private, jwk = rsa_key("current")
    verifier = _verifier(jwk, now)

    absent = verifier.verify(identity_token(private, kid="current", now=now))
    assert absent.name is None
    assert absent.picture is None

    # A blank name must not become a display name of "".
    blank = verifier.verify(
        identity_token(
            private,
            kid="current",
            now=now,
            profile={"name": "   ", "picture": 12345},
        )
    )
    assert blank.name is None
    assert blank.picture is None


def test_an_overlong_name_is_bounded_to_the_column() -> None:
    now = datetime(2026, 9, 1, 18, 0, tzinfo=UTC)
    private, jwk = rsa_key("current")

    claims = _verifier(jwk, now).verify(
        identity_token(
            private,
            kid="current",
            now=now,
            profile={"name": "n" * 500},
        )
    )

    assert claims.name is not None
    assert len(claims.name) == 64
