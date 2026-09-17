import json
from datetime import UTC, datetime
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import update
from sqlalchemy.orm import Session, sessionmaker

from alembic import command
from ladle.api.app import create_app
from ladle.auth.attestation import AttestationService
from ladle.db.models import Recipe
from ladle.db.session import build_engine
from tests.api.test_discover_paging import FIXTURE, _seed
from tests.integration.test_migrations import alembic_config


@pytest.mark.integration
def test_savers_rate_a_source_and_the_average_waits_for_enough_of_them(
    clean_postgres_url: str,
) -> None:
    """One rating per cook, fed into an average nobody can read one cook out of.

    Below the minimum the count is published and the average is null — never
    zero, which would read as a verdict. Only somebody holding a live saved
    copy may rate, and nothing here ever says who did.
    """
    command.upgrade(alembic_config(clean_postgres_url), "head")
    engine = build_engine(clean_postgres_url)
    app = create_app(
        session_factory=sessionmaker(engine, expire_on_commit=False),
        attestation=AttestationService(enforced=False),
    )

    with TestClient(app) as client:
        users = [
            client.post(
                "/v1/auth/guest",
                json={"installationID": f"rating-{index}", "attestation": None},
            ).json()
            for index in range(6)
        ]
        # The first cook saved nothing and only browses; the other five all
        # saved the most popular source.
        browser, *savers = (
            {"Authorization": f"Bearer {user['accessToken']}"} for user in users
        )
        _seed(engine, json.loads(FIXTURE.read_text()), users[1:])

        def discovered() -> dict:
            return client.get("/v1/recipes/discover", headers=browser).json()["items"][
                0
            ]

        unrated = discovered()
        source_id = unrated["sourceID"]
        rating = f"/v1/recipes/discover/{source_id}/rating"
        engagement = f"/v1/recipes/discover/{source_id}/engagement"
        assert (unrated["ratingAverage"], unrated["ratingCount"]) == (None, 0)

        first = client.put(rating, json={"stars": 5}, headers=savers[0])
        assert first.status_code == 200
        assert first.json() == {
            "sourceID": source_id,
            "savedCount": 5,
            # Seeded directly, so nothing ever read the platform's count.
            "likeCount": None,
            "ratingAverage": None,
            "ratingCount": 1,
            "myRating": 5,
        }
        client.put(rating, json={"stars": 4}, headers=savers[1])
        assert client.get(engagement, headers=browser).json()["ratingAverage"] is None

        third = client.put(rating, json={"stars": 4}, headers=savers[2]).json()
        assert (third["ratingAverage"], third["ratingCount"]) == (4.3, 3)

        # Anybody may read the aggregate; only the caller's own rating rides
        # along with it, and the feed carries the same two numbers.
        seen = client.get(engagement, headers=browser).json()
        assert (seen["ratingAverage"], seen["ratingCount"]) == (4.3, 3)
        assert seen["myRating"] is None
        rated = discovered()
        assert (rated["ratingAverage"], rated["ratingCount"]) == (4.3, 3)

        changed = client.put(rating, json={"stars": 1}, headers=savers[2]).json()
        assert (changed["ratingAverage"], changed["ratingCount"]) == (3.3, 3)
        assert changed["myRating"] == 1

        for _ in range(2):
            cleared = client.delete(rating, headers=savers[2])
            assert cleared.status_code == 200
            assert cleared.json()["myRating"] is None
            assert cleared.json()["ratingCount"] == 2
            assert cleared.json()["ratingAverage"] is None

        for stars in (0, 6):
            refused = client.put(rating, json={"stars": stars}, headers=savers[2])
            assert refused.status_code == 422

        unsaved = client.put(rating, json={"stars": 5}, headers=browser)
        assert unsaved.status_code == 409
        assert unsaved.json()["error"]["code"] == "conflict"

        # A deleted copy no longer counts as holding the recipe.
        with Session(engine) as database, database.begin():
            database.execute(
                update(Recipe)
                .where(
                    Recipe.user_id == UUID(users[3]["userID"]),
                    Recipe.source_video_id == UUID(source_id),
                )
                .values(deleted_at=datetime(2026, 9, 17, tzinfo=UTC))
            )
        assert (
            client.put(rating, json={"stars": 5}, headers=savers[2]).status_code == 409
        )
        assert client.get(engagement, headers=browser).json()["savedCount"] == 4

        unknown = f"/v1/recipes/discover/{uuid4()}"
        assert client.get(f"{unknown}/engagement", headers=browser).status_code == 404
        assert (
            client.put(
                f"{unknown}/rating", json={"stars": 3}, headers=savers[0]
            ).status_code
            == 404
        )

    engine.dispose()
