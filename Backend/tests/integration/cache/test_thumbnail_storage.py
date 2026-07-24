from datetime import timedelta

import httpx
import pytest
from testcontainers.minio import MinioContainer

from ladle.infrastructure.object_storage import S3ObjectStorage


@pytest.mark.integration
def test_private_thumbnail_put_signed_read_and_delete() -> None:
    with MinioContainer() as minio:
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
