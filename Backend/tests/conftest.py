import os
from collections.abc import Iterator

import pytest
from sqlalchemy import create_engine, text
from testcontainers.postgres import PostgresContainer


@pytest.fixture(autouse=True)
def isolate_ladle_environment(
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[None]:
    for name in tuple(key for key in os.environ if key.startswith("LADLE_")):
        monkeypatch.delenv(name, raising=False)
    yield


@pytest.fixture(scope="session")
def postgres_url() -> Iterator[str]:
    with PostgresContainer("postgres:16-alpine", driver="psycopg") as postgres:
        yield postgres.get_connection_url()


@pytest.fixture
def clean_postgres_url(postgres_url: str) -> Iterator[str]:
    engine = create_engine(postgres_url)
    with engine.begin() as connection:
        connection.execute(text("DROP SCHEMA public CASCADE"))
        connection.execute(text("CREATE SCHEMA public"))
    engine.dispose()
    yield postgres_url
