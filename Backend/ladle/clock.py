from datetime import UTC, datetime
from typing import Protocol


class Clock(Protocol):
    """Source of timezone-aware UTC timestamps."""

    def now(self) -> datetime:
        """Return a timezone-aware timestamp normalized to UTC."""
        ...


class SystemClock:
    """Production clock backed by the system's UTC time."""

    def now(self) -> datetime:
        return datetime.now(UTC)
