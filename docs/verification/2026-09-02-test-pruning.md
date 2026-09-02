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

### Speed

- **Migrate once, copy per test.** `tests/conftest.py` runs `alembic upgrade
  head` a single time into `ladle_migrated_template`, and `clean_postgres_url`
  hands each test its own `CREATE DATABASE ... TEMPLATE` copy, dropped in
  teardown. Each test still gets a private, pristine database, so nothing about
  isolation changed. The `command.upgrade(..., "head")` line in ~137 tests was
  left alone: it now finds nothing to do (~20 ms), and it keeps each test
  readable without its fixture. 75.1 s -> 41.8 s, no test touched.
- `tests/integration/test_migrations.py` takes a new `empty_postgres_url`
  instead: the migrations are what it tests, so it needs a database with no
  schema. Its `alembic_config` helper moved to `tests/conftest.py` and is
  re-exported, so the modules that import it from there still work.
- **`-n auto` in `addopts`.** Each xdist worker builds its own container and
  template, which is why more workers stop helping: `-n 4` measured 23.5 s and
  `-n auto` (10 workers on this machine) 25.2 s. GitHub's `ubuntu-24.04` runner
  has 4 vCPUs, so `-n auto` resolves to the fast end there. The chaos job passes
  `-n0`, because those tests kill real workers and the marker says they run
  alone.
- **`-m 'not live_provider and not chaos'` in `addopts`.** `uv run pytest` and
  the CI step are now the same command. A command-line `-m` still overrides it,
  which is how the chaos job selects its tier (verified with `--collect-only`).
- **Two CI steps removed.** `Migration metadata consistency` re-ran
  `tests/integration/test_migrations.py`, which the full selection already runs;
  `Real PostgreSQL restore drill` ran `scripts/restore_drill.py`, whose
  `__main__` only prints, while
  `tests/integration/operations/test_restore_drill.py` calls the same function
  and asserts on the result. Both duplicated a fresh set of PostgreSQL
  containers for no extra coverage.
- **UI launches merged.** A UI test costs ~10 s to launch and a second or two to
  assert, so the suite's cost is the number of launches. Six launches went, by
  merging tests that already asserted the same screen from the same launch
  arguments, or by deleting one whose own docstring recorded that it does not
  catch what it exists to catch.

### Kept, though they were candidates

- The 8-case parametrisation of
  `test_staging_verifier::test_secret_rejects_unsafe_header_values_without_leaking_them`.
  The cases probably share one branch, but they are the header-injection guard
  on a value that goes into a request header, and they cost nothing.
- `test_config.py`'s 17-case `test_production_runtime_dependencies_fail_closed`
  and the 12-address SSRF sets: one case per validator or address class, and
  all of them fail-closed security checks.
- `ProjectSmokeTests.testPrimaryScreensAvoidRedundantExplanatoryHeadings`. It
  scans source text, but for UI copy rather than for symbols, so the compiler
  guarantees nothing and nothing else covers it.
- `StateScenarioUITests.testLargeLibraryScenario` alongside
  `testLargeLibraryAtXXXLargeUsesOneReadableColumn`. The content size category
  is a launch argument, so they cannot share a launch, and at XXXL the
  80th card is not materialised for the first test to assert on.
- `DiscoverInteractionUITests.testRecipeOptionsExposeTheDeleteAction`. Folding
  it into the primary journey would need the menu dismissed mid-flow, which is
  fragile in XCUITest for a gain of one launch.
- `DiscoverInteractionUITests.testFailedImportRecoveryActionsShareLabelOrigin`.
  Merged, measured, reverted: with the slow import from the neighbouring test
  still in flight, a second `Add recipe` tap does not present the sheet, so the
  merged test was asserting a different thing. The comment in the file records
  it.

## Affected components

- `Backend/tests/conftest.py`
- `Backend/tests/integration/test_migrations.py`
- `Backend/pyproject.toml`
- `.github/workflows/backend-ci.yml`
- `Backend/tests/unit/deploy/` (three files merged into
  `test_local_stack_policy.py`)
- `Backend/tests/unit/test_frontend_contract.py` (removed)
- `LadleTests/`, `LadleUITests/`
- `README.md`, `AGENTS.md`

## Verification

| Suite | Before | After |
| --- | --- | --- |
| Backend, CI selection | 841 tests, 75.1 s | 827 tests, 16.3 s |
| iOS `LadleTests` | 406 tests, 3.72 s | 404 tests, 3.70 s |
| iOS `LadleUITests` | 26 tests, 350.4 s | 20 tests, 279.2 s |

Commands, all run from this branch:

```bash
# Backend, from Backend/
uv run ruff format --check .      # 326 files already formatted
uv run ruff check .               # All checks passed
uv run mypy --strict ladle        # no issues in 122 source files
uv run pytest                     # 827 passed
uv run pytest -n0                 # 827 passed, serial
uv lock --check                   # lockfile matches pyproject

# iOS, from the repository root, under the xcodebuild watchdog
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests        # 404 tests, 1 skipped, 0 failures
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleUITests      # 20 tests, 0 failures
```

### On CI

`Backend production gate` is the only workflow in the repository and its `paths`
filter is `Backend/**`, so it is the backend rows above that CI confirms; there
is no iOS workflow, and the two iOS rows are local, from an iPhone 17 simulator.

The runner has 4 vCPUs, where `-n auto` resolves to four workers and four
throwaway PostgreSQL containers.

| Step | `main` (run 33591110076) | This branch (run 33593583307) |
| --- | --- | --- |
| Migration metadata consistency | 9 passed in 13.5 s | removed |
| Non-live tests | 841 passed in 92.3 s | **827 passed in 53.7 s** |
| Real PostgreSQL restore drill | 3 s | removed |
| `quality` job, end to end | 2 min 36 s | **1 min 49 s** |

Nothing flaked under `-n auto`, including the three timing-sensitive tests that
led the baseline durations
(`test_a_slow_import_submission_does_not_stall_other_requests`,
`test_sweep_does_not_deadlock_with_a_concurrent_cancellation`,
`test_later_sequence_waits_for_earlier_transaction_commit`).

Two UI merges failed on the first full run and were caught by running the suite
rather than by reasoning about it. One was a sequencing mistake — `Save` belongs
to the page in view, so asserting it after the swipe rather than before is a
different claim — and was fixed. The other changed what was being asserted, and
was reverted; it is recorded above under "Kept, though they were candidates".
The 20 passing tests above are after both.
