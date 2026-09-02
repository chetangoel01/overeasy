# Test Pruning and Suite Speed-up

## Purpose

The suites had grown to 841 backend tests, 406 iOS unit tests and 26 UI tests,
and every change waited on them. Remove the tests that prove something another
test already proves, and make what is left finish sooner — without weakening a
single assertion.

## Baseline, measured before any edit

Machine: Apple Silicon Mac, Docker 29.6.2, iPhone 17 simulator.

| Suite | Command | Tests | Wall time |
| --- | --- | --- | --- |
| Backend CI selection | `uv run pytest -q -m "not live_provider and not chaos"` | 841 | 75.1 s |
| iOS unit | `xcodebuild test … -only-testing:LadleTests` | 406 | 3.7 s (43 s incl. incremental build) |
| iOS UI | `xcodebuild test … -only-testing:LadleUITests` | 26 | 350.4 s |

Backend time by tier, from `--durations=0` (65.9 s of the 68 s run was
accounted for; collection itself is 1.3 s):

| Tier | Tests | Time |
| --- | --- | --- |
| `tests/integration` | 97 | 44.3 s |
| `tests/api` | 40 | 16.2 s |
| `tests/unit` | 661 | 4.3 s |
| `tests/e2e` | 2 | 1.0 s |
| `tests/contracts` | 41 | 0.01 s |

The 661 unit tests were never the problem: they are 4.3 s of a 75 s run. The
cost was ~0.45 s per database test, spread evenly over 137 of them.

### Where the database time actually went

The brief expected per-test containers. There were none to find: `postgres_url`
was already session-scoped, and only four tests start a Redis or MinIO container
(inline, in the test body, ~1.4 s each). The real cost was one line repeated in
every database test:

```python
command.upgrade(alembic_config(clean_postgres_url), "head")
```

`clean_postgres_url` dropped and recreated the `public` schema, so all 16
migrations ran again from empty for each of the 137 tests that wanted a schema.

### Slowest UI tests (baseline)

Every UI test pays ~8–10 s for `app.launch()`, so the suite's cost is the
number of launches, not the number of assertions.

| Test | Time |
| --- | --- |
| `DiscoverInteractionUITests.testReturningToTheTopOffersNothingNewInTheDemoFeed` | 23.8 s |
| `DiscoverInteractionUITests.testSettingsAccentAndRecipeViewPreferencesAreReachable` | 22.3 s |
| `StateScenarioUITests.testPrimaryJourneyCapturesInboxDetailAndCooking` | 21.0 s |
| `DiscoverInteractionUITests.testWatchDefaultsToInlinePlayerWithPlaybackControls` | 19.5 s |
| `DiscoverInteractionUITests.testWatchFeedSelectorSwitchesBetweenSavedAndDiscover` | 18.2 s |
| (21 more, 6.6–17.3 s each) | |

## Decisions

Filled in as the work lands; see the pull request for the per-test table.

## Affected components

- `Backend/tests/conftest.py`
- `Backend/tests/integration/test_migrations.py`
- `Backend/pyproject.toml`
- `.github/workflows/backend-ci.yml`
- `LadleTests/`, `LadleUITests/`
- `README.md`

## Verification

Filled in as the work lands.
