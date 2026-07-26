from collections.abc import Sequence
from datetime import timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.api.rate_limits import RateLimitBackend, RateLimitCheck
from ladle.auth.attestation import AttestationService
from ladle.auth.sessions import SessionService
from ladle.auth.tokens import AccessTokenCodec, RefreshTokenCodec
from ladle.clock import SystemClock
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


class SelectiveRateLimitBackend(RateLimitBackend):
    blocked_bucket: str | None = None

    def retry_after(self, checks: Sequence[RateLimitCheck]) -> int | None:
        return (
            11 if any(check.bucket == self.blocked_bucket for check in checks) else None
        )


@pytest.mark.integration
def test_every_sensitive_route_enforces_its_distributed_policy(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    access_tokens = AccessTokenCodec(
        signing_secret="test-signing-secret-that-is-long-enough",
        issuer="ladle-test",
        lifetime=timedelta(minutes=15),
    )
    backend = SelectiveRateLimitBackend()
    clock = SystemClock()
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        session_service=SessionService(
            access_tokens=access_tokens,
            refresh_tokens=RefreshTokenCodec(),
            refresh_lifetime=timedelta(days=30),
            rotation_grace=timedelta(seconds=5),
            clock=clock,
        ),
        clock=clock,
        access_tokens=access_tokens,
        attestation=AttestationService(enforced=False),
        rate_limit_backend=backend,
    )

    with TestClient(app) as client:
        guest_body = {
            "installationID": "rate-limit-installation",
            "attestation": None,
        }
        backend.blocked_bucket = "guest:installation"
        assert client.post("/v1/auth/guest", json=guest_body).status_code == 429

        backend.blocked_bucket = None
        guest = client.post("/v1/auth/guest", json=guest_body).json()
        authorization = {"Authorization": f"Bearer {guest['accessToken']}"}

        backend.blocked_bucket = "refresh:installation"
        assert (
            client.post(
                "/v1/auth/refresh",
                json={
                    "refreshToken": guest["refreshToken"],
                    "deviceID": guest["deviceID"],
                },
            ).status_code
            == 429
        )

        backend.blocked_bucket = "apple:user"
        assert (
            client.post(
                "/v1/auth/apple",
                headers=authorization,
                json={
                    "identityToken": "identity",
                    "authorizationCode": "code",
                    "nonce": "nonce",
                    "idempotencyKey": "apple-rate-limit",
                },
            ).status_code
            == 429
        )

        job_id = uuid4()
        backend.blocked_bucket = "import-submit:user"
        assert (
            client.post(
                "/v1/imports",
                headers=authorization,
                json={
                    "jobID": str(job_id),
                    "sourceURL": "https://youtu.be/dQw4w9WgXcQ",
                },
            ).status_code
            == 429
        )

        backend.blocked_bucket = "import-retry:installation"
        assert (
            client.post(
                f"/v1/imports/{job_id}/retry",
                headers=authorization,
                json={},
            ).status_code
            == 429
        )

        backend.blocked_bucket = "sync:user"
        assert client.get("/v1/recipes/sync", headers=authorization).status_code == 429

        backend.blocked_bucket = "recipe-mutation:user"
        assert (
            client.delete(
                f"/v1/recipes/{uuid4()}?baseRevision=1",
                headers=authorization,
            ).status_code
            == 429
        )

    engine.dispose()
