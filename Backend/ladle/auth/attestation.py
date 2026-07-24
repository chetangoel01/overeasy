from typing import Protocol


class AttestationRejected(Exception):
    pass


class AttestationVerifier(Protocol):
    def verify(self, *, installation_id: str, assertion: str) -> bool: ...


class AttestationService:
    def __init__(
        self,
        *,
        enforced: bool,
        verifier: AttestationVerifier | None = None,
    ) -> None:
        self._enforced = enforced
        self._verifier = verifier

    def verify(self, *, installation_id: str, assertion: str | None) -> str:
        if not self._enforced:
            return "development"
        if self._verifier is None or assertion is None:
            raise AttestationRejected
        if not self._verifier.verify(
            installation_id=installation_id,
            assertion=assertion,
        ):
            raise AttestationRejected
        return "verified"
