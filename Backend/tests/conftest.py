import os
from collections.abc import Iterator
from contextlib import contextmanager
from itertools import count
from pathlib import Path

import pytest
from alembic.config import Config
from sqlalchemy import create_engine, text
from sqlalchemy.engine import make_url
from testcontainers.postgres import PostgresContainer

from alembic import command

BACKEND_ROOT = Path(__file__).parents[1]
TEMPLATE_DATABASE = "ladle_migrated_template"
_DATABASE_NUMBERS = count(1)


@pytest.fixture(autouse=True)
def isolate_ladle_environment(
    monkeypatch: pytest.MonkeyPatch,
    request: pytest.FixtureRequest,
) -> Iterator[None]:
    if request.node.get_closest_marker("live_provider") is not None:
        yield
        return
    for name in tuple(key for key in os.environ if key.startswith("LADLE_")):
        monkeypatch.delenv(name, raising=False)
    yield


@pytest.fixture(scope="session")
def postgres_url() -> Iterator[str]:
    with PostgresContainer("postgres:16-alpine", driver="psycopg") as postgres:
        yield postgres.get_connection_url()


@pytest.fixture(scope="session")
def migrated_template(postgres_url: str) -> str:
    """Run `alembic upgrade head` once, into a database used as a template.

    Every test that wants a schema used to migrate from scratch, which cost
    roughly 400ms each and dominated the suite. `CREATE DATABASE ... TEMPLATE`
    copies the finished schema in a fraction of that, and each test still gets
    its own database, so the isolation the per-test migration bought is intact.
    """
    with _maintenance(postgres_url) as connection:
        connection.execute(text(f'DROP DATABASE IF EXISTS "{TEMPLATE_DATABASE}"'))
        connection.execute(text(f'CREATE DATABASE "{TEMPLATE_DATABASE}"'))
    with _without_database_url_override():
        command.upgrade(
            alembic_config(_url_for(postgres_url, TEMPLATE_DATABASE)), "head"
        )
    return TEMPLATE_DATABASE


@pytest.fixture
def empty_postgres_url(postgres_url: str) -> Iterator[str]:
    """A database with no schema at all, for the migrations themselves."""
    yield from _database(postgres_url, template=None)


@pytest.fixture
def clean_postgres_url(postgres_url: str, migrated_template: str) -> Iterator[str]:
    """A private database already migrated to head.

    Tests still call `alembic upgrade head` themselves, which now finds nothing
    to do; that keeps each test readable on its own and correct if this fixture
    ever hands back an empty database again.
    """
    yield from _database(postgres_url, template=migrated_template)


def alembic_config(database_url: str) -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", database_url)
    return config


def _database(postgres_url: str, template: str | None) -> Iterator[str]:
    name = f"ladle_test_{next(_DATABASE_NUMBERS)}"
    clause = f' TEMPLATE "{template}"' if template else ""
    with _maintenance(postgres_url) as connection:
        connection.execute(text(f'CREATE DATABASE "{name}"{clause}'))
    try:
        yield _url_for(postgres_url, name)
    finally:
        with _maintenance(postgres_url) as connection:
            connection.execute(text(f'DROP DATABASE "{name}" WITH (FORCE)'))


@contextmanager
def _maintenance(postgres_url: str) -> Iterator[object]:
    """CREATE/DROP DATABASE cannot run inside a transaction."""
    engine = create_engine(postgres_url, isolation_level="AUTOCOMMIT")
    try:
        with engine.connect() as connection:
            yield connection
    finally:
        engine.dispose()


@contextmanager
def _without_database_url_override() -> Iterator[None]:
    """`alembic/env.py` prefers LADLE_DATABASE_URL over the config it is given.

    The autouse environment isolation clears it for every test, but this
    fixture is session-scoped and can be built before that runs.
    """
    previous = os.environ.pop("LADLE_DATABASE_URL", None)
    try:
        yield
    finally:
        if previous is not None:
            os.environ["LADLE_DATABASE_URL"] = previous


def _url_for(postgres_url: str, database: str) -> str:
    # `str(URL)` masks the password; the tests need a URL that can connect.
    return (
        make_url(postgres_url)
        .set(database=database)
        .render_as_string(hide_password=False)
    )
