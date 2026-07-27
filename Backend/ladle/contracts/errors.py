from enum import StrEnum

from pydantic import model_validator

from ladle.contracts.common import WireDateTime, WireModel, WireUUID
from ladle.contracts.recipes import RecipeDTO


class ErrorCode(StrEnum):
    INVALID_REQUEST = "invalidRequest"
    INVALID_URL = "invalidURL"
    UNSUPPORTED_SOURCE = "unsupportedSource"
    DUPLICATE_RECIPE = "duplicateRecipe"
    GUEST_RECIPE_LIMIT_REACHED = "guestRecipeLimitReached"
    AUTHENTICATION_REQUIRED = "authenticationRequired"
    SYNC_CONFLICT = "syncConflict"
    SYNC_RESET_REQUIRED = "syncResetRequired"
    PROVIDER_UNAVAILABLE = "providerUnavailable"
    QUOTA_EXCEEDED = "quotaExceeded"
    RATE_LIMITED = "rateLimited"
    NOT_FOUND = "notFound"
    CONFLICT = "conflict"
    INTERNAL_ERROR = "internalError"


class DuplicateRecipeDetails(WireModel):
    existing_recipe_id: WireUUID


class SyncConflictDetails(WireModel):
    current_recipe: RecipeDTO
    current_revision: int


class RateLimitDetails(WireModel):
    retry_at: WireDateTime


ErrorDetails = DuplicateRecipeDetails | SyncConflictDetails | RateLimitDetails


class ErrorDTO(WireModel):
    code: ErrorCode
    message: str
    retryable: bool
    request_id: WireUUID
    details: ErrorDetails | None = None

    @model_validator(mode="after")
    def validate_details_for_code(self) -> "ErrorDTO":
        if self.code == ErrorCode.DUPLICATE_RECIPE:
            valid_details = isinstance(self.details, DuplicateRecipeDetails)
        elif self.code == ErrorCode.SYNC_CONFLICT:
            valid_details = isinstance(self.details, SyncConflictDetails)
        elif self.code == ErrorCode.RATE_LIMITED:
            valid_details = isinstance(self.details, RateLimitDetails)
        else:
            valid_details = self.details is None

        if not valid_details:
            raise ValueError(f"details do not match {self.code}")
        return self


class ErrorEnvelope(WireModel):
    error: ErrorDTO
