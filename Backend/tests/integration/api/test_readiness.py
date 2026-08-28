import pytest
from sqlalchemy import text
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.routes.health import DatabaseReadinessProbe
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config


@pytest.mark.integration
def test_database_readiness_requires_current_migration_revision(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sessions = sessionmaker(engine)
    # No expected_revision override: constructed exactly as production does
    # (ladle/api/app.py), so the default pin is checked against the real head.
    probe = DatabaseReadinessProbe(sessions)

    probe.check()
    with Session(engine) as database, database.begin():
        database.execute(text("UPDATE alembic_version SET version_num = '0008'"))

    with pytest.raises(RuntimeError, match="migration"):
        probe.check()

    engine.dispose()
