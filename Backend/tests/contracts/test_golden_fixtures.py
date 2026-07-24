import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import UUID

import pytest
from pydantic import TypeAdapter, ValidationError

from ladle.contracts.errors import (
    DuplicateRecipeDetails,
    ErrorCode,
    ErrorDTO,
    ErrorEnvelope,
)
from ladle.contracts.imports import ImportFailure, ImportJobResponse, ImportStatus
from ladle.contracts.recipes import RecipeDTO, SyncPageDTO

FIXTURE_ROOT = Path(__file__).parents[3] / "Contracts" / "Fixtures"
JOB_ID = UUID("10000000-0000-4000-8000-000000000001")
RECIPE_ID = UUID("20000000-0000-4000-8000-000000000001")
REQUEST_ID = UUID("30000000-0000-4000-8000-000000000001")
NOW = datetime(2026, 7, 23, 20, 15, tzinfo=UTC)


def fixture_json(name: str) -> Any:
    with (FIXTURE_ROOT / name).open() as fixture:
        return json.load(fixture)


def canonical_json(value: Any) -> str:
    return json.dumps(value, indent=2, sort_keys=True) + "\n"


@pytest.mark.parametrize(
    ("fixture_name", "adapter"),
    [
        ("import-ready.json", TypeAdapter(ImportJobResponse)),
        ("import-needs-review.json", TypeAdapter(ImportJobResponse)),
        ("import-failures.json", TypeAdapter(list[ImportJobResponse])),
        ("recipe-ready.json", TypeAdapter(RecipeDTO)),
        ("recipe-needs-review.json", TypeAdapter(RecipeDTO)),
        ("sync-page.json", TypeAdapter(SyncPageDTO)),
        ("errors.json", TypeAdapter(list[ErrorEnvelope])),
    ],
)
def test_golden_fixture_round_trips_canonically(
    fixture_name: str,
    adapter: TypeAdapter[Any],
) -> None:
    fixture = fixture_json(fixture_name)

    parsed = adapter.validate_python(fixture)
    rendered = adapter.dump_python(parsed, mode="json", by_alias=True)

    assert canonical_json(rendered) == canonical_json(fixture)


def test_failed_import_is_flat() -> None:
    value = ImportJobResponse(
        job_id=JOB_ID,
        status=ImportStatus.FAILED,
        failure_reason=ImportFailure.PRIVATE_OR_DELETED,
        retry_count=0,
        created_at=NOW,
        updated_at=NOW,
    )

    rendered = value.model_dump(mode="json", by_alias=True)

    assert rendered["status"] == "failed"
    assert rendered["failureReason"] == "privateOrDeleted"
    assert isinstance(rendered["status"], str)


def test_failure_reason_matches_failed_status() -> None:
    with pytest.raises(ValidationError):
        ImportJobResponse(
            job_id=JOB_ID,
            status=ImportStatus.READY,
            failure_reason=ImportFailure.PARSER_UNAVAILABLE,
            recipe_id=RECIPE_ID,
            retry_count=0,
            created_at=NOW,
            updated_at=NOW,
        )


def test_wire_scalars_are_lowercase_fractional_and_string_decimal() -> None:
    fixture = fixture_json("recipe-ready.json")

    parsed = RecipeDTO.model_validate(fixture)
    rendered = parsed.model_dump(mode="json", by_alias=True)

    assert rendered["id"] == str(RECIPE_ID)
    assert rendered["createdAt"].endswith(".000Z")
    assert rendered["servings"] == "4"
    assert isinstance(rendered["nutrition"]["calories"], str)

    fixture["servings"] = 4
    with pytest.raises(ValidationError):
        RecipeDTO.model_validate(fixture)


def test_error_details_are_code_specific_and_nullable() -> None:
    duplicate = ErrorEnvelope(
        error=ErrorDTO(
            code=ErrorCode.DUPLICATE_RECIPE,
            message="Already saved.",
            retryable=False,
            request_id=REQUEST_ID,
            details=DuplicateRecipeDetails(existing_recipe_id=RECIPE_ID),
        )
    )
    generic = ErrorEnvelope(
        error=ErrorDTO(
            code=ErrorCode.PROVIDER_UNAVAILABLE,
            message="Try again later.",
            retryable=True,
            request_id=REQUEST_ID,
            details=None,
        )
    )

    assert duplicate.model_dump(mode="json", by_alias=True)["error"]["details"] == {
        "existingRecipeID": str(RECIPE_ID)
    }
    assert generic.model_dump(mode="json", by_alias=True)["error"]["details"] is None
