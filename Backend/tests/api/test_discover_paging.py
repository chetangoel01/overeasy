import json
from datetime import UTC, datetime
from decimal import Decimal
from pathlib import Path
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.db.models import ExtractionCache, Recipe, SourceVideo
from ladle.db.session import build_engine
from tests.integration.test_migrations import alembic_config

FIXTURE = Path(__file__).parents[3] / "Contracts" / "Fixtures" / "recipe-ready.json"

# Titles chosen so search can be asserted against a known subset: three
# "Lemon" sources and two that must not match.
# Only two sources have counts; the rest are NULL like a pre-existing corpus.
LIKES = {"Smash Burgers": 9_000, "Preserved Lemon Salad": 5_000}

TITLES = [
    "Lemon Orzo",
    "Lemon Chicken",
    "Garlic Butter Udon",
    "Preserved Lemon Salad",
    "Smash Burgers",
]

# When each source arrived in Overeasy, as minutes past the seed hour.
# Deliberately not the save ranking, the like ranking or A-to-Z, so an
# assertion on "newest" cannot pass by agreeing with another order.
ARRIVED = {
    "Lemon Orzo": 1,
    "Garlic Butter Udon": 2,
    "Smash Burgers": 3,
    "Lemon Chicken": 4,
    "Preserved Lemon Salad": 5,
}

# The first saver's total time for the three sources that carry one. Later
# savers of the same source get progressively slower copies, so a shelf
# filtered on time is exercised against the minimum rather than any one
# saver's edit. The two sources missing here keep a NULL total, which is
# absent rather than quick.
FIRST_SAVER_MINUTES = {
    "Lemon Orzo": 20,
    "Garlic Butter Udon": 15,
    "Lemon Chicken": 90,
}


def _template(recipe: dict, title: str, source_url: str) -> dict:
    return {
        "title": title,
        "description": recipe["description"],
        "creatorName": "@mia_cooks",
        "source": "tiktok",
        "originalURL": source_url,
        "servings": "4",
        "ingredients": [
            {
                "quantityText": "1 cup",
                "normalizedQuantity": "1",
                "unit": "cup",
                "name": "orzo",
                "preparation": None,
                "orderIndex": 0,
                "uncertainty": None,
            }
        ],
        "steps": [
            {
                "orderIndex": 0,
                "instruction": "Cook until tender.",
                "ingredientIndexes": [0],
                "timers": [],
                "sourceStartSeconds": None,
                "sourceEndSeconds": None,
                "uncertainty": None,
            }
        ],
        "notes": [],
        "reviewStatus": "ready",
        "uncertainties": [],
    }


def _seed(engine, recipe: dict, savers: list[dict]) -> None:
    """One source per title, saved by a decreasing number of users.

    Source 0 is saved by every user, source 1 by one fewer, and so on, which
    makes the popular ordering exactly TITLES order and gives paging something
    deterministic to walk.
    """
    with Session(engine) as database, database.begin():
        for index, title in enumerate(TITLES):
            source_id = uuid4()
            cache_id = uuid4()
            source_url = f"https://www.tiktok.com/@mia_cooks/video/{1000 + index}"
            database.add(
                SourceVideo(
                    id=source_id,
                    platform="tiktok",
                    platform_video_id=str(1000 + index),
                    canonical_url=source_url,
                    public_access_confirmed_at=datetime(2026, 8, 23, 12, tzinfo=UTC),
                    source_revision="1",
                    source_metadata={},
                    # Only the last two carry counts, and in the reverse of
                    # the save ranking, so "most liked" cannot accidentally
                    # agree with "popular". The rest stay NULL, standing in
                    # for a corpus imported before counts existed.
                    like_count=LIKES.get(title),
                    # Set rather than left to the server default: every row
                    # would otherwise share one timestamp and "newest" would
                    # fall through to the source id.
                    created_at=datetime(2026, 8, 20, 9, ARRIVED[title], tzinfo=UTC),
                )
            )
            database.flush()
            database.add(
                ExtractionCache(
                    id=cache_id,
                    source_video_id=source_id,
                    source_revision="1",
                    contract_version="v1",
                    prompt_version="recipe-test",
                    model_id="test-model",
                    template_json=_template(recipe, title, source_url),
                    review_status="ready",
                    thumbnail_remote_url=recipe["images"][0]["remoteURL"],
                )
            )
            for rank, saver in enumerate(savers[: len(TITLES) - index]):
                first_saver_minutes = FIRST_SAVER_MINUTES.get(title)
                database.add(
                    Recipe(
                        id=uuid4(),
                        user_id=UUID(saver["userID"]),
                        source_video_id=source_id,
                        source_cache_id=cache_id,
                        # Savers keep the template's title, which is the
                        # ordinary case and what search matches on.
                        title=title,
                        description=recipe["description"],
                        creator_name="@mia_cooks",
                        source="tiktok",
                        original_url=source_url,
                        total_minutes=(
                            None
                            if first_saver_minutes is None
                            else first_saver_minutes + rank * 30
                        ),
                        servings=Decimal(4),
                        favorite=False,
                        review_status="ready",
                        revision=1,
                        created_at=datetime(2026, 8, 23, 12, rank, tzinfo=UTC),
                        updated_at=datetime(2026, 8, 23, 12, rank, tzinfo=UTC),
                    )
                )


def _titles(payload: dict) -> list[str]:
    return [item["title"] for item in payload["items"]]


@pytest.mark.integration
def test_discover_pages_searches_and_sorts(clean_postgres_url: str) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )
    recipe = json.loads(FIXTURE.read_text())

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={"installationID": f"discover-page-{index}", "attestation": None},
            ).json()
            for index in range(6)
        ]
        # users[0] is the reader and saves nothing, so every source is public
        # to them; the rest are the savers that build the ranking.
        headers = {"Authorization": f"Bearer {users[0]['accessToken']}"}
        _seed(engine, recipe, users[1:])

        # --- paging walks the whole feed without repeating or skipping ---
        first = client.get("/v1/recipes/discover?limit=2", headers=headers)
        assert first.status_code == 200
        assert _titles(first.json()) == ["Lemon Orzo", "Lemon Chicken"]
        assert first.json()["nextCursor"] == 2
        assert first.json()["hasMore"] is True

        second = client.get(
            f"/v1/recipes/discover?limit=2&cursor={first.json()['nextCursor']}",
            headers=headers,
        )
        assert _titles(second.json()) == ["Garlic Butter Udon", "Preserved Lemon Salad"]
        assert second.json()["hasMore"] is True

        third = client.get(
            f"/v1/recipes/discover?limit=2&cursor={second.json()['nextCursor']}",
            headers=headers,
        )
        assert _titles(third.json()) == ["Smash Burgers"]
        assert third.json()["hasMore"] is False
        assert third.json()["nextCursor"] == 5

        # --- search runs on the server, across the whole corpus ---
        found = client.get("/v1/recipes/discover?q=lemon", headers=headers)
        assert sorted(_titles(found.json())) == [
            "Lemon Chicken",
            "Lemon Orzo",
            "Preserved Lemon Salad",
        ]
        assert found.json()["hasMore"] is False

        # A term only reachable beyond the first page still matches, which is
        # the whole point of moving search off the client.
        tail = client.get("/v1/recipes/discover?q=smash&limit=2", headers=headers)
        assert _titles(tail.json()) == ["Smash Burgers"]

        # --- search paginates too ---
        paged = client.get("/v1/recipes/discover?q=lemon&limit=2", headers=headers)
        assert len(paged.json()["items"]) == 2
        assert paged.json()["hasMore"] is True

        # --- alphabetical sort orders the whole corpus, not one page ---
        alpha = client.get(
            "/v1/recipes/discover?sort=alphabetical&limit=2", headers=headers
        )
        assert _titles(alpha.json()) == ["Garlic Butter Udon", "Lemon Chicken"]

        # --- LIKE wildcards are literal, not operators ---
        wildcard = client.get("/v1/recipes/discover?q=%25", headers=headers)
        assert wildcard.json()["items"] == []

        # --- no match is an empty page, not an error ---
        missing = client.get("/v1/recipes/discover?q=zzzznope", headers=headers)
        assert missing.status_code == 200
        assert missing.json()["items"] == []
        assert missing.json()["hasMore"] is False

    engine.dispose()


@pytest.mark.integration
def test_discover_most_liked_ranks_counted_sources_first(
    clean_postgres_url: str,
) -> None:
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )
    recipe = json.loads(FIXTURE.read_text())

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={"installationID": f"discover-likes-{index}", "attestation": None},
            ).json()
            for index in range(6)
        ]
        headers = {"Authorization": f"Bearer {users[0]['accessToken']}"}
        _seed(engine, recipe, users[1:])

        page = client.get("/v1/recipes/discover?sort=mostLiked", headers=headers).json()

        titles = _titles(page)
        # The two counted sources lead, most-liked first, even though both sit
        # last under the save ranking.
        assert titles[:2] == ["Smash Burgers", "Preserved Lemon Salad"]
        # Uncounted sources sort last rather than first, which is what a bare
        # DESC would do with NULLs — and they fall back to save order.
        assert titles[2:] == ["Lemon Orzo", "Lemon Chicken", "Garlic Butter Udon"]
        assert page["items"][0]["likeCount"] == 9_000
        assert page["items"][-1]["likeCount"] is None

        # Paging stays consistent under the ties the null tail is full of.
        first = client.get(
            "/v1/recipes/discover?sort=mostLiked&limit=2", headers=headers
        ).json()
        second = client.get(
            f"/v1/recipes/discover?sort=mostLiked&limit=2&cursor={first['nextCursor']}",
            headers=headers,
        ).json()
        third = client.get(
            f"/v1/recipes/discover?sort=mostLiked&limit=2"
            f"&cursor={second['nextCursor']}",
            headers=headers,
        ).json()
        walked = _titles(first) + _titles(second) + _titles(third)
        assert walked == titles
        assert len(set(walked)) == len(walked)

    engine.dispose()


@pytest.mark.integration
def test_discover_newest_orders_by_when_the_source_arrived(
    clean_postgres_url: str,
) -> None:
    """The "New to Overeasy" shelf.

    Keyed on `SourceVideo.created_at` rather than `published_at`: the latter
    is nullable and absent for Instagram, so it would silently drop a whole
    platform out of the shelf that is meant to show what just arrived.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )
    recipe = json.loads(FIXTURE.read_text())

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={
                    "installationID": f"discover-newest-{index}",
                    "attestation": None,
                },
            ).json()
            for index in range(6)
        ]
        headers = {"Authorization": f"Bearer {users[0]['accessToken']}"}
        _seed(engine, recipe, users[1:])

        page = client.get("/v1/recipes/discover?sort=newest", headers=headers).json()

        newest_first = sorted(TITLES, key=lambda title: -ARRIVED[title])
        assert _titles(page) == newest_first
        # The shelf is the ranked feed under a different order, so it has to
        # differ from every order the feed already had.
        assert _titles(page) != TITLES
        assert _titles(page) != sorted(TITLES)

        # A shelf asks for a short first page, and this is the feed's own
        # sort menu too, so the cursor invariants still have to hold.
        first = client.get(
            "/v1/recipes/discover?sort=newest&limit=2", headers=headers
        ).json()
        assert first["nextCursor"] == 2
        assert first["hasMore"] is True
        second = client.get(
            f"/v1/recipes/discover?sort=newest&limit=2&cursor={first['nextCursor']}",
            headers=headers,
        ).json()
        third = client.get(
            f"/v1/recipes/discover?sort=newest&limit=2&cursor={second['nextCursor']}",
            headers=headers,
        ).json()
        walked = _titles(first) + _titles(second) + _titles(third)
        assert walked == newest_first
        assert len(set(walked)) == len(walked)
        assert third["hasMore"] is False

    engine.dispose()


@pytest.mark.integration
def test_discover_max_total_minutes_excludes_slow_and_untimed_sources(
    clean_postgres_url: str,
) -> None:
    """The "Quick dinners" shelf.

    A filter on the existing feed rather than a new endpoint, so the shelf
    and the list beneath it return the same shape and the same DTO.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )
    recipe = json.loads(FIXTURE.read_text())

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={
                    "installationID": f"discover-quick-{index}",
                    "attestation": None,
                },
            ).json()
            for index in range(6)
        ]
        headers = {"Authorization": f"Bearer {users[0]['accessToken']}"}
        _seed(engine, recipe, users[1:])

        quick = client.get(
            "/v1/recipes/discover?max_total_minutes=30", headers=headers
        ).json()

        # Lemon Orzo's first saver says 20 minutes and its later savers say
        # 50 and up, so the source qualifies on the minimum across savers.
        assert _titles(quick) == ["Lemon Orzo", "Garlic Butter Udon"]
        # Lemon Chicken is timed but slow; the other two carry no total at
        # all and are absent rather than assumed quick.
        assert "Lemon Chicken" not in _titles(quick)
        assert "Smash Burgers" not in _titles(quick)
        assert quick["hasMore"] is False

        # The filter composes with the other criteria rather than replacing
        # them: still the popular ranking, still searchable, still paged.
        searched = client.get(
            "/v1/recipes/discover?max_total_minutes=30&q=lemon", headers=headers
        ).json()
        assert _titles(searched) == ["Lemon Orzo"]

        first = client.get(
            "/v1/recipes/discover?max_total_minutes=30&limit=1", headers=headers
        ).json()
        assert _titles(first) == ["Lemon Orzo"]
        assert first["hasMore"] is True
        second = client.get(
            "/v1/recipes/discover?max_total_minutes=30&limit=1"
            f"&cursor={first['nextCursor']}",
            headers=headers,
        ).json()
        assert _titles(second) == ["Garlic Butter Udon"]
        assert second["hasMore"] is False

        # A wider window admits the slow source and still drops the untimed
        # ones — NULL is never quick, however generous the bound.
        wide = client.get(
            "/v1/recipes/discover?max_total_minutes=120", headers=headers
        ).json()
        assert _titles(wide) == ["Lemon Orzo", "Lemon Chicken", "Garlic Butter Udon"]

        # Zero minutes is not a recipe, and the upper bound is the one the
        # recipe contract already uses for a stored total.
        assert (
            client.get(
                "/v1/recipes/discover?max_total_minutes=0", headers=headers
            ).status_code
            == 422
        )

    engine.dispose()
