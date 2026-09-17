from datetime import timedelta

import httpx
import pytest
from testcontainers.minio import MinioContainer

from ladle.infrastructure.object_storage import S3ObjectStorage


@pytest.mark.integration
def test_private_thumbnail_put_signed_read_and_delete() -> None:
    # Use the same release as Compose. Docker Hub removed minio/minio;
    # the publisher's Quay registry still serves these pinned images.
    with MinioContainer(
        "quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z"
        "@sha256:a1ea29fa28355559ef137d71fc570e508a214ec84ff8083e39bc5428980b015e"
    ) as minio:
        config = minio.get_config()
        storage = S3ObjectStorage(
            endpoint_url=f"http://{config['endpoint']}",
            region="us-east-1",
            bucket="ladle-private",
            access_key=config["access_key"],
            secret_key=config["secret_key"],
        )
        storage.create_private_bucket()
        key = "thumbnails/shared-video.jpg"
        storage.put(
            key,
            b"thumbnail-bytes",
            content_type="image/jpeg",
        )

        unsigned = httpx.get(
            f"http://{config['endpoint']}/ladle-private/{key}",
            timeout=5,
        )
        assert unsigned.status_code == 403

        signed_url = storage.signed_read_url(key, expires_in=timedelta(minutes=5))
        response = httpx.get(signed_url, timeout=5)
        assert response.status_code == 200
        assert response.content == b"thumbnail-bytes"
        assert response.headers["content-type"] == "image/jpeg"

        storage.delete(key)
        assert not storage.exists(key)
