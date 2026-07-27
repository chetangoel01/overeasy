"""Exercise a real pg_dump -> empty PostgreSQL restore and verify its contents."""

import hashlib
import json
import subprocess
from typing import TypedDict

from sqlalchemy import create_engine, text
from testcontainers.postgres import PostgresContainer


class RestoreDrillResult(TypedDict):
    rowsRestored: int
    sourceChecksum: str
    restoredChecksum: str
    sourceVersion: str
    restoredVersion: str


def run_restore_drill() -> RestoreDrillResult:
    image = "postgres:16-alpine"
    options = {
        "username": "drill",
        "password": "drill-password",
        "dbname": "drill",
        "driver": "psycopg",
    }
    with (
        PostgresContainer(image, **options) as source,
        PostgresContainer(image, **options) as restored,
    ):
        source_engine = create_engine(source.get_connection_url())
        restored_engine = create_engine(restored.get_connection_url())
        with source_engine.begin() as connection:
            connection.execute(
                text(
                    "CREATE TABLE restore_probe "
                    "(id integer PRIMARY KEY, payload text NOT NULL)"
                )
            )
            connection.execute(
                text(
                    "INSERT INTO restore_probe (id, payload) "
                    "VALUES (1, 'first'), (2, 'second')"
                )
            )

        source_id = source.get_wrapped_container().id
        restored_id = restored.get_wrapped_container().id
        dump = subprocess.run(
            [
                "docker",
                "exec",
                source_id,
                "pg_dump",
                "-U",
                options["username"],
                "-d",
                options["dbname"],
                "--format=custom",
                "--no-owner",
                "--no-acl",
            ],
            check=True,
            stdout=subprocess.PIPE,
        )
        subprocess.run(
            [
                "docker",
                "exec",
                "-i",
                restored_id,
                "pg_restore",
                "-U",
                options["username"],
                "-d",
                options["dbname"],
                "--no-owner",
                "--no-acl",
                "--exit-on-error",
            ],
            check=True,
            input=dump.stdout,
        )

        source_rows, source_version = _probe(source_engine)
        restored_rows, restored_version = _probe(restored_engine)
        source_engine.dispose()
        restored_engine.dispose()
        return {
            "rowsRestored": len(restored_rows),
            "sourceChecksum": _checksum(source_rows),
            "restoredChecksum": _checksum(restored_rows),
            "sourceVersion": source_version,
            "restoredVersion": restored_version,
        }


def _probe(engine: object) -> tuple[list[tuple[int, str]], str]:
    with engine.connect() as connection:  # type: ignore[attr-defined]
        rows = [
            (int(row.id), str(row.payload))
            for row in connection.execute(
                text("SELECT id, payload FROM restore_probe ORDER BY id")
            )
        ]
        version = str(connection.scalar(text("SHOW server_version")))
    return rows, version


def _checksum(rows: list[tuple[int, str]]) -> str:
    value = json.dumps(rows, separators=(",", ":")).encode()
    return hashlib.sha256(value).hexdigest()


if __name__ == "__main__":
    print(json.dumps(run_restore_drill(), sort_keys=True))
