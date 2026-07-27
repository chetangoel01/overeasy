import json
from pathlib import Path
from unittest.mock import patch

import pytest

from ladle.infrastructure.object_storage_init import main


def test_object_storage_initializer_applies_checked_in_policy(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    policy = {"Rules": [{"ID": "temporary"}]}
    policy_path = tmp_path / "lifecycle.json"
    policy_path.write_text(json.dumps(policy))
    values = {
        "LADLE_OBJECT_STORAGE_ENDPOINT_URL": "https://objects.example.test",
        "LADLE_OBJECT_STORAGE_REGION": "us-east-1",
        "LADLE_OBJECT_STORAGE_BUCKET": "ladle-private",
        "LADLE_OBJECT_STORAGE_ACCESS_KEY": "access",
        "LADLE_OBJECT_STORAGE_SECRET_KEY": "secret",
        "LADLE_OBJECT_STORAGE_ADDRESSING_STYLE": "path",
        "LADLE_OBJECT_STORAGE_LIFECYCLE_PATH": str(policy_path),
    }
    for name, value in values.items():
        monkeypatch.setenv(name, value)

    with patch(
        "ladle.infrastructure.object_storage_init.S3ObjectStorage"
    ) as storage_type:
        main()

    storage_type.assert_called_once_with(
        endpoint_url="https://objects.example.test",
        region="us-east-1",
        bucket="ladle-private",
        access_key="access",
        secret_key="secret",
        addressing_style="path",
    )
    storage_type.return_value.configure_private_bucket.assert_called_once_with(policy)
