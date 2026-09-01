from datetime import UTC, datetime, timedelta
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

from alembic import command

BACKEND_ROOT = Path(__file__).parents[2]
EXPECTED_TABLES = {
    "account_deletion_audits",
    "alembic_version",
    "app_attest_challenges",
    "app_attest_keys",
    "apple_identities",
    "auth_sessions",
    "detected_timers",
    "devices",
    "extraction_cache",
    "extraction_claims",
    "field_uncertainties",
    "google_identities",
    "import_dead_letters",
    "import_dispatch_outbox",
    "import_jobs",
    "import_quota_events",
    "ingredients",
    "negative_extraction_cache",
    "nutrition",
    "object_deletion_queue",
    "other_nutrients",
    "provider_attempts",
    "provider_budget_windows",
    "recipe_changes",
    "recipe_images",
    "recipe_slot_reservations",
    "recipe_steps",
    "recipes",
    "source_videos",
    "step_ingredients",
    "usda_foods",
    "usda_searches",
    "user_sync_state",
    "users",
}


def alembic_config(database_url: str) -> Config:
    config = Config(str(BACKEND_ROOT / "alembic.ini"))
    config.set_main_option("sqlalchemy.url", database_url)
    return config


@pytest.mark.integration
def test_upgrade_from_empty_database_creates_complete_schema(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = create_engine(clean_postgres_url)

    assert set(inspect(engine).get_table_names()) == EXPECTED_TABLES

    engine.dispose()


@pytest.mark.integration
def test_migrated_schema_matches_model_metadata(clean_postgres_url: str) -> None:
    config = alembic_config(clean_postgres_url)
    command.upgrade(config, "head")

    command.check(config)


@pytest.mark.integration
def test_provider_cost_migration_upgrades_and_downgrades(
    clean_postgres_url: str,
) -> None:
    config = alembic_config(clean_postgres_url)
    command.upgrade(config, "head")
    engine = create_engine(clean_postgres_url)

    columns = {
        value["name"]: value
        for value in inspect(engine).get_columns("provider_attempts")
    }
    assert columns["cost_usd"]["type"].precision == 18
    assert columns["cost_usd"]["type"].scale == 8

    engine.dispose()
    command.downgrade(config, "0012")
    engine = create_engine(clean_postgres_url)
    names = {
        value["name"] for value in inspect(engine).get_columns("provider_attempts")
    }
    assert "cost_usd" not in names
    engine.dispose()


@pytest.mark.integration
def test_unique_and_foreign_key_constraints_are_enforced(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = create_engine(clean_postgres_url)
    user_id = uuid4()
    now = datetime.now(UTC)

    with engine.begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO users (id, kind, created_at)
                VALUES (:id, 'guest', :created_at)
                """
            ),
            {"id": user_id, "created_at": now},
        )
        connection.execute(
            text(
                """
                INSERT INTO apple_identities (apple_sub, user_id, created_at)
                VALUES ('apple-user', :user_id, :created_at)
                """
            ),
            {"user_id": user_id, "created_at": now},
        )

    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(
            text(
                """
                    INSERT INTO apple_identities (apple_sub, user_id, created_at)
                    VALUES ('apple-user', :user_id, :created_at)
                    """
            ),
            {"user_id": user_id, "created_at": now},
        )

    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(
            text(
                """
                    INSERT INTO recipes (
                        id, user_id, title, description, source, original_url,
                        servings, favorite, review_status, revision,
                        created_at, updated_at
                    )
                    VALUES (
                        :id, :missing_user_id, 'Orphan', '', 'other',
                        'https://manual.ladle.local/orphan', 1, false, 'ready',
                        1, :created_at, :created_at
                    )
                    """
            ),
            {
                "id": uuid4(),
                "missing_user_id": uuid4(),
                "created_at": now,
            },
        )

    engine.dispose()


@pytest.mark.integration
def test_step_ingredient_references_must_belong_to_the_same_recipe(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = create_engine(clean_postgres_url)
    user_id = uuid4()
    first_recipe_id = uuid4()
    second_recipe_id = uuid4()
    ingredient_id = uuid4()
    step_id = uuid4()
    now = datetime.now(UTC)

    with engine.begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO users (id, kind, created_at)
                VALUES (:id, 'guest', :created_at)
                """
            ),
            {"id": user_id, "created_at": now},
        )
        for recipe_id in (first_recipe_id, second_recipe_id):
            connection.execute(
                text(
                    """
                    INSERT INTO recipes (
                        id, user_id, title, description, source, original_url,
                        servings, favorite, review_status, revision,
                        created_at, updated_at
                    )
                    VALUES (
                        :id, :user_id, 'Recipe', '', 'other', :original_url,
                        1, false, 'ready', 1, :created_at, :created_at
                    )
                    """
                ),
                {
                    "id": recipe_id,
                    "user_id": user_id,
                    "original_url": f"https://manual.ladle.local/{recipe_id}",
                    "created_at": now,
                },
            )
        connection.execute(
            text(
                """
                INSERT INTO ingredients (
                    id, recipe_id, name, order_index
                ) VALUES (:id, :recipe_id, 'salt', 0)
                """
            ),
            {"id": ingredient_id, "recipe_id": first_recipe_id},
        )
        connection.execute(
            text(
                """
                INSERT INTO recipe_steps (
                    id, recipe_id, order_index, instruction
                ) VALUES (:id, :recipe_id, 0, 'Season.')
                """
            ),
            {"id": step_id, "recipe_id": second_recipe_id},
        )

    with pytest.raises(IntegrityError), engine.begin() as connection:
        connection.execute(
            text(
                """
                    INSERT INTO step_ingredients (
                        recipe_id, step_id, ingredient_id
                    ) VALUES (:recipe_id, :step_id, :ingredient_id)
                    """
            ),
            {
                "recipe_id": second_recipe_id,
                "step_id": step_id,
                "ingredient_id": ingredient_id,
            },
        )

    engine.dispose()


@pytest.mark.integration
def test_cancelled_import_downgrade_preserves_jobs_and_their_quota_events(
    clean_postgres_url: str,
) -> None:
    """Downgrading past 0014 must not destroy the audit and quota trail.

    import_quota_events.import_job_id cascades, so deleting cancelled jobs
    silently refunds the user's monthly import quota and takes the billing
    trail with it.
    """
    config = alembic_config(clean_postgres_url)
    command.upgrade(config, "head")
    engine = create_engine(clean_postgres_url)
    user_id = uuid4()
    job_id = uuid4()
    now = datetime.now(UTC)

    with engine.begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO users (id, kind, created_at)
                VALUES (:id, 'guest', :created_at)
                """
            ),
            {"id": user_id, "created_at": now},
        )
        connection.execute(
            text(
                """
                INSERT INTO import_jobs (
                    id, user_id, source_url, source, status, stage,
                    retry_count, idempotency_key, created_at, updated_at
                )
                VALUES (
                    :id, :user_id, 'https://www.tiktok.com/@cook/video/1',
                    'tiktok', 'cancelled', 'cancelled', 0, :key,
                    :created_at, :created_at
                )
                """
            ),
            {
                "id": job_id,
                "user_id": user_id,
                "key": str(job_id),
                "created_at": now,
            },
        )
        connection.execute(
            text(
                """
                INSERT INTO import_quota_events (
                    id, user_id, import_job_id, operation, event_key,
                    occurred_at
                )
                VALUES (
                    :id, :user_id, :job_id, 'submit', :event_key, :occurred_at
                )
                """
            ),
            {
                "id": uuid4(),
                "user_id": user_id,
                "job_id": job_id,
                "event_key": f"submit-{job_id}",
                "occurred_at": now,
            },
        )

    engine.dispose()
    command.downgrade(config, "0013")
    engine = create_engine(clean_postgres_url)

    with engine.begin() as connection:
        job = connection.execute(
            text("SELECT status, failure_reason FROM import_jobs WHERE id = :id"),
            {"id": job_id},
        ).one_or_none()
        quota_events = connection.execute(
            text(
                """
                SELECT count(*) FROM import_quota_events
                WHERE import_job_id = :job_id
                """
            ),
            {"job_id": job_id},
        ).scalar_one()

    assert job is not None, "the cancelled job was deleted by the downgrade"
    assert job.status == "failed"
    assert job.failure_reason is not None
    assert quota_events == 1

    engine.dispose()


@pytest.mark.integration
def test_identity_uniqueness_migration_dedupes_and_enforces_one_per_user(
    clean_postgres_url: str,
) -> None:
    """0015 must collapse duplicate provider identities deterministically
    (oldest row per user, ties broken by subject), leave single identities
    untouched, and enforce uniqueness afterwards — reversibly."""
    config = alembic_config(clean_postgres_url)
    command.upgrade(config, "0014")
    engine = create_engine(clean_postgres_url)
    duplicated_user = uuid4()
    single_user = uuid4()
    now = datetime.now(UTC)

    with engine.begin() as connection:
        for user_id in (duplicated_user, single_user):
            connection.execute(
                text(
                    """
                    INSERT INTO users (id, kind, created_at)
                    VALUES (:id, 'apple', :created_at)
                    """
                ),
                {"id": user_id, "created_at": now},
            )
        for sub, user_id, created_at in (
            ("apple-newer", duplicated_user, now),
            ("apple-older", duplicated_user, now - timedelta(days=1)),
            ("apple-single", single_user, now),
        ):
            connection.execute(
                text(
                    """
                    INSERT INTO apple_identities (apple_sub, user_id, created_at)
                    VALUES (:sub, :user_id, :created_at)
                    """
                ),
                {"sub": sub, "user_id": user_id, "created_at": created_at},
            )
        # Same timestamp: the subject is the deterministic tie-break.
        for sub in ("google-b", "google-a"):
            connection.execute(
                text(
                    """
                    INSERT INTO google_identities (google_sub, user_id, created_at)
                    VALUES (:sub, :user_id, :created_at)
                    """
                ),
                {"sub": sub, "user_id": duplicated_user, "created_at": now},
            )

    command.upgrade(config, "head")

    with engine.connect() as connection:
        apple_subs = set(
            connection.execute(text("SELECT apple_sub FROM apple_identities")).scalars()
        )
        google_subs = set(
            connection.execute(
                text("SELECT google_sub FROM google_identities")
            ).scalars()
        )
    assert apple_subs == {"apple-older", "apple-single"}
    assert google_subs == {"google-a"}

    with (
        pytest.raises(IntegrityError, match="uq_apple_identities_user_id"),
        engine.begin() as connection,
    ):
        connection.execute(
            text(
                """
                INSERT INTO apple_identities (apple_sub, user_id, created_at)
                VALUES ('apple-second', :user_id, :created_at)
                """
            ),
            {"user_id": duplicated_user, "created_at": now},
        )

    command.downgrade(config, "0014")
    with engine.begin() as connection:
        connection.execute(
            text(
                """
                INSERT INTO apple_identities (apple_sub, user_id, created_at)
                VALUES ('apple-second', :user_id, :created_at)
                """
            ),
            {"user_id": duplicated_user, "created_at": now},
        )

    engine.dispose()


@pytest.mark.integration
def test_recipe_child_foreign_key_indexes_upgrade_and_downgrade(
    clean_postgres_url: str,
) -> None:
    """The three recipe child tables filtered on every fetch and delete —
    detected_timers, field_uncertainties, other_nutrients — must index the
    foreign-key column those filters use; Postgres does not index FK
    referencing columns on its own, so without these every read is a
    sequential scan of a globally growing table. Reversibly."""
    expected = {
        "detected_timers": "ix_detected_timers_recipe_step_id",
        "field_uncertainties": "ix_field_uncertainties_recipe_id",
        "other_nutrients": "ix_other_nutrients_nutrition_recipe_id",
    }
    config = alembic_config(clean_postgres_url)
    command.upgrade(config, "head")
    engine = create_engine(clean_postgres_url)
    for table, index in expected.items():
        names = {value["name"] for value in inspect(engine).get_indexes(table)}
        assert index in names, f"{table} has no index on its foreign key: {names}"
    engine.dispose()

    command.downgrade(config, "0015")
    engine = create_engine(clean_postgres_url)
    for table, index in expected.items():
        names = {value["name"] for value in inspect(engine).get_indexes(table)}
        assert index not in names
    engine.dispose()
