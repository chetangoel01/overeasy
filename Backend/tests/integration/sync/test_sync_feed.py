from dataclasses import dataclass
from datetime import UTC, datetime
from decimal import Decimal
from uuid import UUID, uuid4

import pytest
from pydantic import AnyHttpUrl
from sqlalchemy import event
from sqlalchemy.orm import Session

from alembic import command
from ladle.contracts.recipes import (
    RecipeDTO,
    RecipeReviewStatus,
    RecipeSource,
    SyncChangeKind,
)
from ladle.db.models import UserSyncState
from ladle.db.session import build_engine
from ladle.observability.metrics import MetricsRegistry
from ladle.recipes.service import RecipeService
from ladle.sync.service import RecipeSyncService, SyncCursorExpired
from tests.integration.recipes.test_recipe_service import (
    manual_recipe,
    seed_user,
)
from tests.integration.test_migrations import alembic_config


@dataclass
class FrozenClock:
    value: datetime

    def now(self) -> datetime:
        return self.value


@pytest.mark.integration
def test_cursor_pagination_has_no_gaps_or_duplicates(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipes = RecipeService(clock=FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC)))
    metrics = MetricsRegistry()
    sync = RecipeSyncService(metrics=metrics)

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        for index in range(3):
            recipes.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(uuid4(), title=f"Recipe {index}"),
                base_revision=0,
            )

    with Session(engine) as database:
        first = sync.page(database, user_id=user_id, cursor=0, limit=2)
        second = sync.page(
            database,
            user_id=user_id,
            cursor=first.next_cursor,
            limit=2,
        )
        replay = sync.page(database, user_id=user_id, cursor=0, limit=2)

    assert [change.sequence for change in first.changes] == [1, 2]
    assert first.has_more
    assert [change.sequence for change in second.changes] == [3]
    assert not second.has_more
    assert replay == first
    assert {change.recipe_id for change in first.changes}.isdisjoint(
        {change.recipe_id for change in second.changes}
    )
    assert 'ladle_sync_total{outcome="success"} 3' in metrics.render()

    engine.dispose()


@pytest.mark.integration
def test_pruned_cursor_requires_a_full_snapshot_restart(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sync = RecipeSyncService()
    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        state = database.get(UserSyncState, user_id)
        assert state is not None
        state.next_sequence = 9
        state.minimum_retained_sequence = 7

    with Session(engine) as database:
        with pytest.raises(SyncCursorExpired) as raised:
            sync.page(database, user_id=user_id, cursor=4, limit=100)
        assert raised.value.minimum_retained_sequence == 7
        assert (
            sync.page(
                database,
                user_id=user_id,
                cursor=0,
                limit=100,
            ).changes
            == []
        )

    engine.dispose()


def minimal_recipe(recipe_id: UUID) -> RecipeDTO:
    """A valid manual recipe with no images, steps, timers, uncertainties
    or nutrition — the emptiest graph the wire contract admits."""
    moment = datetime(2026, 7, 23, 21, 0, tzinfo=UTC)
    return RecipeDTO(
        id=recipe_id,
        title="Bare Broth",
        description="",
        source=RecipeSource.OTHER,
        original_url=AnyHttpUrl(f"https://manual.ladle.local/{recipe_id}"),
        servings=Decimal(1),
        is_favorite=False,
        review_status=RecipeReviewStatus.READY,
        revision=1,
        created_at=moment,
        updated_at=moment,
    )


@pytest.mark.integration
def test_sync_page_statement_count_does_not_grow_with_the_page(
    clean_postgres_url: str,
) -> None:
    """One sync page must cost a fixed number of statements. The per-change
    find() + to_dto() loop cost ~9 statements per change, so a 100-change
    page fanned out to ~900 sequential queries on one pooled connection."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipes = RecipeService(
        clock=FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    )
    sync = RecipeSyncService()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        for index in range(6):
            recipes.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(uuid4(), title=f"Recipe {index}"),
                base_revision=0,
            )

    statements: list[str] = []

    def record(*args: object) -> None:
        statements.append(str(args[2]))

    def statements_for_page(limit: int) -> int:
        statements.clear()
        with Session(engine) as database:
            page = sync.page(database, user_id=user_id, cursor=0, limit=limit)
        assert len(page.changes) == limit
        assert all(change.recipe is not None for change in page.changes)
        return len(statements)

    event.listen(engine, "before_cursor_execute", record)
    try:
        two_changes = statements_for_page(2)
        six_changes = statements_for_page(6)
    finally:
        event.remove(engine, "before_cursor_execute", record)
    engine.dispose()

    assert six_changes == two_changes, (
        f"a 6-change page cost {six_changes} statements against "
        f"{two_changes} for a 2-change page: the page fans out per change"
    )


@pytest.mark.integration
def test_all_tombstone_page_needs_no_per_recipe_queries(
    clean_postgres_url: str,
) -> None:
    """A page in which every change resolves to a tombstone materialises no
    recipe bodies, so its cost must not grow with the number of tombstones
    and it must never touch the recipe child tables."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    recipes = RecipeService(
        clock=FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    )
    sync = RecipeSyncService()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        recipe_ids = [uuid4() for _ in range(4)]
        for recipe_id in recipe_ids:
            recipes.upsert(
                database,
                user_id=user_id,
                recipe=manual_recipe(recipe_id),
                base_revision=0,
            )
        for recipe_id in recipe_ids:
            recipes.delete(
                database,
                user_id=user_id,
                recipe_id=recipe_id,
                base_revision=1,
            )

    statements: list[str] = []

    def record(*args: object) -> None:
        statements.append(str(args[2]))

    def statements_for_page(limit: int) -> int:
        statements.clear()
        with Session(engine) as database:
            page = sync.page(database, user_id=user_id, cursor=0, limit=limit)
        assert len(page.changes) == limit
        for change in page.changes:
            assert change.kind == SyncChangeKind.DELETE
            assert change.recipe is None
            assert change.recipe_revision == 2
        return len(statements)

    event.listen(engine, "before_cursor_execute", record)
    try:
        two_changes = statements_for_page(2)
        eight_changes = statements_for_page(8)
    finally:
        event.remove(engine, "before_cursor_execute", record)
    engine.dispose()

    assert not any("ingredients" in statement for statement in statements)
    assert eight_changes == two_changes, (
        f"an 8-tombstone page cost {eight_changes} statements against "
        f"{two_changes} for 2: the page still looks recipes up one by one"
    )


@pytest.mark.integration
def test_empty_sync_page_issues_no_recipe_queries(
    clean_postgres_url: str,
) -> None:
    """A user with no changes gets a page built from the sync-state read and
    the change-window read alone — no recipe or child-table queries."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    sync = RecipeSyncService()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)

    statements: list[str] = []

    def record(*args: object) -> None:
        statements.append(str(args[2]))

    event.listen(engine, "before_cursor_execute", record)
    try:
        with Session(engine) as database:
            page = sync.page(database, user_id=user_id, cursor=0, limit=100)
    finally:
        event.remove(engine, "before_cursor_execute", record)
    engine.dispose()

    assert page.changes == []
    assert page.next_cursor == 0
    assert not page.has_more
    assert len(statements) == 2, statements
    assert not any("FROM recipes" in statement for statement in statements)


@pytest.mark.integration
def test_batched_page_matches_single_recipe_reads(
    clean_postgres_url: str,
) -> None:
    """A mixed page — a full graph, an empty graph, a tombstone — must render
    each recipe exactly as a single-recipe read does, with no leakage of one
    recipe's children into its page neighbours."""
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    clock = FrozenClock(datetime(2026, 7, 23, 21, 0, tzinfo=UTC))
    recipes = RecipeService(clock=clock)
    sync = RecipeSyncService()
    full_id, bare_id, doomed_id = uuid4(), uuid4(), uuid4()

    with Session(engine) as database, database.begin():
        user_id = seed_user(database)
        for recipe in (
            manual_recipe(full_id),
            minimal_recipe(bare_id),
            manual_recipe(doomed_id, title="Doomed"),
        ):
            recipes.upsert(
                database,
                user_id=user_id,
                recipe=recipe,
                base_revision=0,
            )
        recipes.delete(
            database,
            user_id=user_id,
            recipe_id=doomed_id,
            base_revision=1,
        )

    with Session(engine) as database:
        page = sync.page(database, user_id=user_id, cursor=0, limit=10)
        expected_full = recipes.get(
            database, user_id=user_id, recipe_id=full_id
        )
        expected_bare = recipes.get(
            database, user_id=user_id, recipe_id=bare_id
        )
    engine.dispose()

    full, bare, doomed_upsert, doomed_delete = page.changes
    assert full.kind == SyncChangeKind.UPSERT
    assert full.recipe == expected_full
    assert full.recipe is not None and full.recipe.nutrition is not None
    assert bare.kind == SyncChangeKind.UPSERT
    assert bare.recipe == expected_bare
    assert bare.recipe is not None
    assert bare.recipe.images == []
    assert bare.recipe.steps == []
    assert bare.recipe.ingredients == []
    assert bare.recipe.uncertainties == []
    assert bare.recipe.nutrition is None
    for change in (doomed_upsert, doomed_delete):
        assert change.kind == SyncChangeKind.DELETE
        assert change.recipe is None
        assert change.recipe_revision == 2
