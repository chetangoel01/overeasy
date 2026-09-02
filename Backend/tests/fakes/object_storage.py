"""A private bucket in a dictionary.

Stands in for `S3ObjectStorage` wherever a test cares about which key an object
landed under rather than about S3 itself — the avatar routes, mostly. The
signed URL it mints is a stable, obviously fake one carrying the key, so a test
can assert the URL the app is served points at the object the route stored.
"""

from dataclasses import dataclass, field
from datetime import timedelta


@dataclass
class FakeObjectStorage:
    objects: dict[str, tuple[bytes, str]] = field(default_factory=dict)
    deleted: list[str] = field(default_factory=list)

    def put(self, key: str, data: bytes, *, content_type: str) -> None:
        self.objects[key] = (data, content_type)

    def signed_read_url(self, key: str, *, expires_in: timedelta) -> str:
        seconds = int(expires_in.total_seconds())
        if seconds <= 0:
            raise ValueError("signed URL lifetime must be positive")
        return f"https://objects.test/{key}?signature=fake&expires={seconds}"

    def delete(self, key: str) -> None:
        self.deleted.append(key)
        self.objects.pop(key, None)

    def exists(self, key: str) -> bool:
        return key in self.objects
