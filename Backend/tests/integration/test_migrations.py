from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

import pytest
from alembic.config import Config
from sqlalchemy import create_engine, inspect, text
from sqlalchemy.exc import IntegrityError

from alembic import command

BACKEND_ROOT = Path(__file__).parents[2]
EXPECTED_TABLES = {
    "alembic_version",
    "apple_identities",
    "auth_sessions",
    "detected_timers",
    "devices",
    "extraction_cache",
    "extraction_claims",
    "field_uncertainties",
    "import_jobs",
    "ingredients",
    "negative_extraction_cache",
    "nutrition",
    "other_nutrients",
    "provider_attempts",
    "recipe_changes",
    "recipe_images",
    "recipe_slot_reservations",
    "recipe_steps",
    "recipes",
    "source_videos",
    "step_ingredients",
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
