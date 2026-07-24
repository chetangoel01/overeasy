from datetime import UTC, datetime
from decimal import Decimal, InvalidOperation
from typing import Annotated
from uuid import UUID

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    PlainSerializer,
)
from pydantic.alias_generators import to_camel


def _to_wire_alias(field_name: str) -> str:
    return to_camel(field_name).replace("Id", "ID").replace("Url", "URL")


class WireModel(BaseModel):
    """Strict DTO base with Ladle's lower-camel-case wire convention."""

    model_config = ConfigDict(
        alias_generator=_to_wire_alias,
        extra="forbid",
        validate_by_alias=True,
        validate_by_name=True,
    )


def _parse_wire_uuid(value: object) -> UUID:
    if isinstance(value, UUID):
        return value
    if not isinstance(value, str):
        raise ValueError("UUID values must be lowercase strings")
    parsed = UUID(value)
    if value != str(parsed):
        raise ValueError("UUID values must be lowercase hyphenated strings")
    return parsed


WireUUID = Annotated[UUID, BeforeValidator(_parse_wire_uuid)]


def _parse_wire_decimal(value: object) -> Decimal:
    if isinstance(value, Decimal):
        return value
    if not isinstance(value, str):
        raise ValueError("decimal values must be strings")
    try:
        return Decimal(value)
    except InvalidOperation as error:
        raise ValueError("invalid decimal string") from error


def _serialize_wire_decimal(value: Decimal) -> str:
    return format(value, "f")


WireDecimal = Annotated[
    Decimal,
    BeforeValidator(_parse_wire_decimal),
    PlainSerializer(_serialize_wire_decimal, return_type=str, when_used="json"),
]


def _require_utc(value: datetime) -> datetime:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("timestamps must be timezone-aware")
    if value.utcoffset() != UTC.utcoffset(value):
        raise ValueError("timestamps must use UTC")
    return value.astimezone(UTC)


def _serialize_wire_datetime(value: datetime) -> str:
    return (
        value.astimezone(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    )


WireDateTime = Annotated[
    datetime,
    AfterValidator(_require_utc),
    PlainSerializer(_serialize_wire_datetime, return_type=str, when_used="json"),
]
