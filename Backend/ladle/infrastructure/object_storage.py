from datetime import timedelta
from typing import Any, Protocol

import boto3
from botocore.client import BaseClient
from botocore.config import Config
from botocore.exceptions import ClientError


class ObjectStorage(Protocol):
    def put(self, key: str, data: bytes, *, content_type: str) -> None: ...

    def signed_read_url(self, key: str, *, expires_in: timedelta) -> str: ...

    def delete(self, key: str) -> None: ...

    def exists(self, key: str) -> bool: ...


class S3ObjectStorage:
    def __init__(
        self,
        *,
        endpoint_url: str,
        region: str,
        bucket: str,
        access_key: str,
        secret_key: str,
        public_endpoint_url: str | None = None,
    ) -> None:
        self._bucket = bucket
        addressing = Config(s3={"addressing_style": "path"})
        self._client: BaseClient = boto3.client(
            "s3",
            endpoint_url=endpoint_url,
            region_name=region,
            aws_access_key_id=access_key,
            aws_secret_access_key=secret_key,
            config=addressing,
        )
        # Presigned URLs must carry a host the app can reach; storage
        # operations keep using the internal endpoint.
        self._signing_client: BaseClient = self._client
        if public_endpoint_url is not None:
            self._signing_client = boto3.client(
                "s3",
                endpoint_url=public_endpoint_url,
                region_name=region,
                aws_access_key_id=access_key,
                aws_secret_access_key=secret_key,
                config=addressing,
            )

    def create_private_bucket(self) -> None:
        try:
            self._client.head_bucket(Bucket=self._bucket)
            return
        except ClientError as error:
            status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            if status not in {403, 404}:
                raise
        self._client.create_bucket(Bucket=self._bucket)

    def put(self, key: str, data: bytes, *, content_type: str) -> None:
        self._client.put_object(
            Bucket=self._bucket,
            Key=key,
            Body=data,
            ContentType=content_type,
        )

    def signed_read_url(self, key: str, *, expires_in: timedelta) -> str:
        seconds = int(expires_in.total_seconds())
        if seconds <= 0:
            raise ValueError("signed URL lifetime must be positive")
        value: Any = self._signing_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": self._bucket, "Key": key},
            ExpiresIn=seconds,
        )
        return str(value)

    def delete(self, key: str) -> None:
        self._client.delete_object(Bucket=self._bucket, Key=key)

    def exists(self, key: str) -> bool:
        try:
            self._client.head_object(Bucket=self._bucket, Key=key)
        except ClientError as error:
            status = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode")
            if status == 404:
                return False
            raise
        return True
