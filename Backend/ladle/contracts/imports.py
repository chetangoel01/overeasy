from enum import StrEnum

from pydantic import Field, model_validator

from ladle.contracts.common import WireDateTime, WireModel, WireUUID


class ImportStatus(StrEnum):
    PARSING = "parsing"
    READY = "ready"
    NEEDS_REVIEW = "needsReview"
    FAILED = "failed"
    # The database CHECK constraint permits this and ImportCancellationService
    # writes it, so an idempotent re-submission can match a cancelled job.
    CANCELLED = "cancelled"


class ImportFailure(StrEnum):
    PARSER_UNAVAILABLE = "parserUnavailable"
    INSUFFICIENT_TEXT_EVIDENCE = "insufficientTextEvidence"
    PRIVATE_OR_DELETED = "privateOrDeleted"
    UNSUPPORTED_SOURCE = "unsupportedSource"
    INVALID_URL = "invalidURL"
    NETWORK_UNAVAILABLE = "networkUnavailable"
    QUOTA_EXCEEDED = "quotaExceeded"


class ImportJobResponse(WireModel):
    job_id: WireUUID
    status: ImportStatus
    failure_reason: ImportFailure | None = None
    recipe_id: WireUUID | None = None
    retry_count: int = Field(ge=0)
    created_at: WireDateTime
    updated_at: WireDateTime

    @model_validator(mode="after")
    def validate_terminal_value(self) -> "ImportJobResponse":
        if self.status == ImportStatus.FAILED:
            if self.failure_reason is None:
                raise ValueError("failed imports require a failure reason")
            if self.recipe_id is not None:
                raise ValueError("failed imports cannot expose a candidate recipe")
        elif self.failure_reason is not None:
            raise ValueError("only failed imports may include a failure reason")

        if self.status in {ImportStatus.READY, ImportStatus.NEEDS_REVIEW}:
            if self.recipe_id is None:
                raise ValueError("successful terminal imports require a recipe ID")
        elif (
            self.status in {ImportStatus.PARSING, ImportStatus.CANCELLED}
            and self.recipe_id is not None
        ):
            raise ValueError(
                "parsing and cancelled imports cannot expose a candidate recipe"
            )
        return self
