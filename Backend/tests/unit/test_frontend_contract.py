"""The shared fixtures are the app's stated expectation; hold the API to them.

`Contracts/Fixtures/` is checked into the repo root and read by the iOS tests
(LadleCoreTests, RemoteImportServiceTests, RecipeSyncServiceTests) as the shape
the client decodes. Until now only the client asserted against them, so the
server could change a field name or drop a key and every backend test would
still pass while the app failed to decode in the user's hands.

These parse the same files with the server's own DTOs. If a rename lands on
one side only, this fails on the other.
"""

import json
from pathlib import Path

import pytest

from ladle.contracts.imports import ImportJobResponse
from ladle.contracts.recipes import RecipeDTO

FIXTURES = Path(__file__).resolve().parents[3] / "Contracts" / "Fixtures"


def load(name: str) -> dict:
    return dict(_raw(name))


def _raw(name: str) -> object:
    return json.loads((FIXTURES / name).read_text())


@pytest.mark.parametrize("name", ["recipe-ready.json", "recipe-needs-review.json"])
def test_the_app_s_recipe_fixture_decodes_as_the_server_s_recipe(name: str) -> None:
    recipe = RecipeDTO.model_validate(load(name))

    # Round-tripping is the real assertion: the server must be able to emit
    # every key the client expects, spelled the way the client reads it.
    emitted = recipe.model_dump(mode="json", by_alias=True)
    missing = set(load(name)) - set(emitted)
    assert not missing, f"server would not emit {sorted(missing)}"


@pytest.mark.parametrize(
    "name", ["import-ready.json", "import-needs-review.json", "import-failures.json"]
)
def test_the_app_s_import_fixtures_decode_as_the_server_s_job(name: str) -> None:
    payload = _raw(name)
    entries = payload if isinstance(payload, list) else [payload]
    checked = 0
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        for candidate in [entry, *entry.values()]:
            if isinstance(candidate, dict) and "jobID" in candidate:
                ImportJobResponse.model_validate(candidate)
                checked += 1
    assert checked, f"{name} carried no job the server recognises"


def test_step_timing_survives_the_round_trip() -> None:
    """sourceStartSeconds is in the fixture, so the client is entitled to it.

    No view renders it yet — the platform embeds the app opens cannot seek —
    but it is part of the agreed shape, and dropping it server-side would be
    a silent breaking change rather than a deliberate one.
    """

    recipe = RecipeDTO.model_validate(load("recipe-needs-review.json"))
    emitted = recipe.model_dump(mode="json", by_alias=True)

    assert "sourceStartSeconds" in emitted["steps"][0]
    assert "sourceEndSeconds" in emitted["steps"][0]


def test_uncertainty_reaches_the_cook_as_written() -> None:
    """IngredientList and MethodList render `reason` verbatim to the user."""

    recipe = RecipeDTO.model_validate(load("recipe-needs-review.json"))
    emitted = recipe.model_dump(mode="json", by_alias=True)

    assert emitted["uncertainties"], "review state with no reason tells nobody why"
    for entry in emitted["uncertainties"]:
        assert set(entry) >= {"field", "reason"}
