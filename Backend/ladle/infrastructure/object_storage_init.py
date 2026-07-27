import json
import os
from pathlib import Path
from typing import Any, cast

from ladle.infrastructure.object_storage import S3ObjectStorage


def main() -> None:
    raw_lifecycle: object = json.loads(
        Path(os.environ["LADLE_OBJECT_STORAGE_LIFECYCLE_PATH"]).read_text()
    )
    if not isinstance(raw_lifecycle, dict):
        raise ValueError("object-storage lifecycle policy must be an object")

    storage = S3ObjectStorage(
        endpoint_url=os.environ["LADLE_OBJECT_STORAGE_ENDPOINT_URL"],
        region=os.environ["LADLE_OBJECT_STORAGE_REGION"],
        bucket=os.environ["LADLE_OBJECT_STORAGE_BUCKET"],
        access_key=os.environ["LADLE_OBJECT_STORAGE_ACCESS_KEY"],
        secret_key=os.environ["LADLE_OBJECT_STORAGE_SECRET_KEY"],
        addressing_style=os.environ.get(
            "LADLE_OBJECT_STORAGE_ADDRESSING_STYLE",
            "auto",
        ),
    )
    storage.configure_private_bucket(cast(dict[str, Any], raw_lifecycle))


if __name__ == "__main__":
    main()
