from typing import cast

from fastapi import APIRouter, Request, status
from pydantic import Field

from ladle.api.dependencies import database
from ladle.auth.attestation import (
    AppAttestPurpose,
    AttestationService,
    IssuedAppAttestChallenge,
)
from ladle.contracts.common import WireDateTime, WireModel, WireUUID

router = APIRouter(prefix="/v1/attestation", tags=["attestation"])


class AppAttestChallengeRequest(WireModel):
    installation_id: str = Field(min_length=1, max_length=255)
    purpose: AppAttestPurpose
    key_id: str | None = Field(default=None, min_length=1, max_length=255)


class AppAttestChallengeResponse(WireModel):
    challenge_id: WireUUID
    challenge: str
    expires_at: WireDateTime
    requires_attestation: bool

    @classmethod
    def from_challenge(
        cls,
        value: IssuedAppAttestChallenge,
    ) -> "AppAttestChallengeResponse":
        return cls(
            challenge_id=value.id,
            challenge=value.challenge,
            expires_at=value.expires_at,
            requires_attestation=value.requires_attestation,
        )


@router.post(
    "/challenges",
    response_model=AppAttestChallengeResponse,
    status_code=status.HTTP_201_CREATED,
)
def issue_challenge(
    request: Request,
    body: AppAttestChallengeRequest,
) -> AppAttestChallengeResponse:
    service = cast(AttestationService, request.app.state.attestation)
    with database(request) as current_database, current_database.begin():
        challenge = service.issue_challenge(
            current_database,
            installation_id=body.installation_id,
            purpose=body.purpose,
            key_id=body.key_id,
        )
    return AppAttestChallengeResponse.from_challenge(challenge)
