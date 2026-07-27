from unittest.mock import Mock, patch

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


def test_s3_bucket_initialization_enables_versioning_and_lifecycle() -> None:
    client = Mock()
    client.head_bucket.return_value = {}
    lifecycle = {"Rules": [{"ID": "temporary"}]}

    with patch(
        "ladle.infrastructure.object_storage.boto3.client",
        return_value=client,
    ):
        storage = S3ObjectStorage(
            endpoint_url="https://objects.example.test",
            region="us-east-1",
            bucket="ladle-private",
            access_key="access",
            secret_key="secret",
        )
        storage.configure_private_bucket(lifecycle)

    client.put_bucket_versioning.assert_called_once_with(
        Bucket="ladle-private",
        VersioningConfiguration={"Status": "Enabled"},
    )
    client.put_bucket_lifecycle_configuration.assert_called_once_with(
        Bucket="ladle-private",
        LifecycleConfiguration=lifecycle,
    )
