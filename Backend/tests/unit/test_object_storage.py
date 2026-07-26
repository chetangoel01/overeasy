from unittest.mock import patch

from ladle.infrastructure.object_storage import S3ObjectStorage


def test_s3_addressing_style_is_configurable_for_railway_buckets() -> None:
    with patch("ladle.infrastructure.object_storage.boto3.client") as client:
        S3ObjectStorage(
            endpoint_url="https://objects.example.test",
            public_endpoint_url="https://cdn.example.test",
            region="us-east-1",
            bucket="ladle-private",
            access_key="access",
            secret_key="secret",
            addressing_style="virtual",
        )

    assert client.call_count == 2
    assert all(
        call.kwargs["config"].s3 == {"addressing_style": "virtual"}
        for call in client.call_args_list
    )
