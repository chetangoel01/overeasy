# Consolidated Final Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce one clean branch containing every still-valid historical capability, the approved final design, explicit application states, and no known incomplete or unused implementation.

**Architecture:** Keep SwiftData as the offline-first source of truth and model remote availability separately so connectivity failures never erase local presentation. Integrate the guarded local backend path on top of the migration tree, centralize remote failure classification, expose sync state to the interface, and finish the semantic design migration before the final repository-wide audit.

**Tech Stack:** Swift 6, SwiftUI, Observation, SwiftData, XCTest, XCUITest, Python 3.12, FastAPI, Celery, Docker Compose, pytest, Ruff, mypy, and shell deployment tooling.

---

## Task 1: Establish the consolidation ledger and baseline

**Files:**

- Create: `docs/verification/2026-08-26-consolidation-audit.md`
- Modify: `docs/plans/2026-08-26-consolidated-final-design.md`

**Step 1: Record the authoritative branch tips**

Run:

```bash
git for-each-ref refs/heads/codex --sort=refname \
  --format='%(refname:short)|%(objectname)|%(subject)'
```

Record every historical branch, its unique-commit count relative to the
consolidation base, and its final disposition.

**Step 2: Record the baseline gates**

Run:

```bash
swift test --package-path Packages/LadleCore
(cd Backend && uv run ruff check .)
(cd Backend && uv run mypy ladle)
(cd Backend && uv run pytest -m 'not integration and not chaos and not live_provider' -q)
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,id=4EDF9686-A28A-4733-9B9D-C78FDCEB632F' \
  -only-testing:LadleTests CODE_SIGNING_ALLOWED=NO
```

Expected baseline: 45 LadleCore tests, 613 selected backend tests, Ruff and
mypy clean, and 195 app tests with one known skip.

**Step 3: Capture known baseline debt**

Record the unconfigured SwiftLint findings, Share Confirmation lifecycle
warnings, unused asset candidates, legacy component counts, raw token counts,
and files over 400 lines. Distinguish audit signals from project gates.

**Step 4: Verify and commit**

Run `git diff --check`, then commit:

```bash
git add docs/plans/2026-08-26-consolidated-final-design.md \
  docs/verification/2026-08-26-consolidation-audit.md
git commit -m "docs: record consolidation baseline"
```

## Task 2: Integrate bounded local Docker operation

**Files:**

- Modify: `Backend/tests/unit/deploy/test_container_hardening.py`
- Modify: `Backend/.env.example`
- Modify: `Backend/docker-compose.yml`
- Modify: `Backend/README.md`
- Modify: `Backend/docs/integration-reference.md`
- Create: `docs/verification/2026-08-24-local-docker-reliability.md`

**Step 1: Write the failing deployment test**

Add a test that loads Compose YAML and requires `api`, `worker`, and `beat` to
restart unless stopped, plus a worker concurrency of one and bounded CPU and
memory:

```python
def test_local_long_running_services_recover_and_worker_avoids_memory_overlap() -> None:
    compose = yaml.safe_load((BACKEND / "docker-compose.yml").read_text())
    services = compose["services"]
    for name in ("api", "worker", "beat"):
        assert services[name]["restart"] == "unless-stopped"
    worker = services["worker"]
    assert worker["mem_limit"] == "${LADLE_WORKER_MEMORY_LIMIT:-2g}"
    assert worker["cpus"] == "${LADLE_WORKER_CPU_LIMIT:-2.0}"
    assert "--concurrency=${LADLE_WORKER_CONCURRENCY:-1}" in worker["command"]
```

**Step 2: Verify red**

Run:

```bash
cd Backend && uv run pytest \
  tests/unit/deploy/test_container_hardening.py::test_local_long_running_services_recover_and_worker_avoids_memory_overlap -q
```

Expected: failure because the migration tree lacks the restart and resource
limits.

**Step 3: Implement the bounded profile**

Port the valid settings from commit `a2787d4`, preserving any newer migration
tree behavior. Document the defaults and operational rationale.

**Step 4: Verify green and refactor**

Run the focused test, the complete deployment unit directory, Ruff, and
`docker compose config --quiet`.

**Step 5: Document and commit**

Run `git diff --check`, then commit:

```bash
git commit -am "fix: bound local Docker worker resources"
```

## Task 3: Integrate the guarded device tunnel

**Files:**

- Modify: `Backend/tests/unit/deploy/test_container_hardening.py`
- Modify: `Backend/tests/unit/deploy/test_mac_mini_profile.py`
- Modify: `Backend/deploy/mac-mini/ngrok.sh`
- Modify: `Backend/docker-compose.yml`
- Create: `Backend/scripts/device_tunnel.sh`
- Modify: `Backend/README.md`
- Modify: `Backend/docs/integration-reference.md`
- Modify: `README.md`
- Create: `docs/verification/2026-08-24-guarded-device-tunnel.md`

**Step 1: Write the failing edge-profile test**

Require an opt-in `device-tunnel` profile, loopback-only port `4114`, read-only
filesystem, dropped capabilities, no-new-privileges, and healthy API/MinIO
dependencies.

**Step 2: Write the failing launcher test**

Require the tunnel script to write `.private/DeviceTunnel.xcconfig`, set the
API URL, disable App Attest only for this local build, write a tunnel key with
mode `600`, hide metrics, and verify missing/wrong keys fail.

**Step 3: Verify red**

Run the two focused deployment tests. Expected: failure because the edge
profile and orchestration script do not exist.

**Step 4: Implement the guarded tunnel**

Port commit `fa34486` semantically. Preserve the existing API configuration
contract, use `launchctl` on macOS, generate keys atomically, and never expose
the backend listener beyond loopback.

**Step 5: Verify green**

Run:

```bash
cd Backend
uv run pytest tests/unit/deploy/test_container_hardening.py \
  tests/unit/deploy/test_mac_mini_profile.py -q
uv run ruff check .
docker compose --profile device-tunnel config --quiet
```

Run shell syntax checks with `sh -n` for both scripts.

**Step 6: Document and commit**

Run `git diff --check`, then commit the tunnel as one coherent change.

## Task 4: Define one remote-failure vocabulary

**Files:**

- Create: `Ladle/Remote/RemoteFailure.swift`
- Create: `LadleTests/RemoteFailureTests.swift`
- Modify: `project.yml`
- Modify: `Ladle.xcodeproj/project.pbxproj`
- Modify: `docs/verification/2026-08-26-consolidation-audit.md`

**Step 1: Write failing classification tests**

Require deterministic mapping for:

```swift
XCTAssertEqual(RemoteFailure(APIError.transport), .offline)
XCTAssertEqual(
    RemoteFailure(APIError.remote(rateLimitedError)),
    .rateLimited(retryAt: retryAt)
)
XCTAssertEqual(
    RemoteFailure(APIError.remote(providerUnavailableError)),
    .serviceUnavailable
)
XCTAssertEqual(
    RemoteFailure(APIError.remote(quotaError)),
    .quotaExceeded
)
XCTAssertEqual(
    RemoteFailure(APIError.authenticationExpired),
    .authenticationExpired
)
```

Also require concise titles, messages, retry eligibility, and retry timing.

**Step 2: Verify red**

Run only `RemoteFailureTests`; expect a compile failure because the type does
not exist.

**Step 3: Implement the failure vocabulary**

Use an app-level `Equatable, Sendable` enum with cases for offline, service
unavailable, rate limited, quota exhausted, authentication expired, invalid
response, and unknown. Keep server messages out of primary user copy while
retaining request IDs for diagnostics.

**Step 4: Regenerate the project and verify green**

Run `xcodegen generate`, the focused tests, `APIClientTests`, and
`ProjectSmokeTests`.

**Step 5: Commit**

Run `git diff --check`, then commit the shared vocabulary and generated project
changes.

## Task 5: Expose coalesced sync and connectivity state

**Files:**

- Create: `Ladle/Sync/SyncStatus.swift`
- Create: `LadleTests/SyncStatusTests.swift`
- Modify: `Ladle/App/LadleApp.swift`
- Modify: `Ladle/Library/LibraryView.swift`
- Modify: `Ladle/Account/AccountSheet.swift`
- Modify: `project.yml`
- Modify: `Ladle.xcodeproj/project.pbxproj`

**Step 1: Write failing state-transition tests**

Prove idle to syncing to current, syncing to offline, rate-limited with retry
time, authentication expiry, and recovery after a later successful sync.

**Step 2: Verify red**

Run only `SyncStatusTests`; expect a compile failure.

**Step 3: Implement `SyncStatus`**

Create an observable main-actor model that records the current state and last
successful sync without owning networking. Add a single app helper that wraps
every existing sync trigger so no `try? await syncService.synchronize()` call
silently discards a user-visible failure.

**Step 4: Present status without hiding content**

Add a compact semantic connectivity banner to the workspace and use the real
status in Settings. Offline and degraded states keep local content visible;
authentication expiry retains the existing welcome transition.

**Step 5: Verify green**

Run focused status tests, sync-service tests, account presentation tests, and
the complete `LadleTests` target.

**Step 6: Commit**

Update the audit record, run `git diff --check`, and commit.

## Task 6: Separate local load failure from empty content

**Files:**

- Modify: `LadleTests/LibraryViewModelTests.swift`
- Modify: `LadleTests/LibraryNavigationStateTests.swift`
- Modify: `Ladle/Library/LibraryViewModel.swift`
- Modify: `Ladle/Library/LibraryView.swift`
- Modify: `Ladle/Library/ImportInboxView.swift`
- Modify: `Ladle/Library/WatchView.swift`

**Step 1: Write the failing repository-reload test**

Load recipes successfully, make the repository fail, and assert that the view
model preserves recipes/import jobs while exposing the load error.

**Step 2: Write the failing initial-load UI contract test**

Require a local repository failure to block all four workspace tabs with a
retry state instead of showing an empty Inbox or saved Watch feed.

**Step 3: Verify red**

Run the focused view-model and navigation tests. The existing implementation
must fail because `load()` clears all arrays.

**Step 4: Implement content-preserving load state**

Preserve the last successful snapshot on reload failure, gate the workspace on
an initial load error, and use an inline recoverable message when cached local
content exists.

**Step 5: Add the large-library case**

Test at least 1,000 deterministic recipes through query, sort, filter, Watch
ordering, and collection counts. Do not add eager UI containers.

**Step 6: Verify and commit**

Run focused tests, complete library tests, `git diff --check`, update the audit
record, and commit.

## Task 7: Preserve remote content through refresh failures

**Files:**

- Modify: `LadleTests/DiscoverViewModelTests.swift`
- Modify: `Ladle/Library/DiscoverView.swift`
- Modify: `Ladle/Library/WatchView.swift`
- Modify: `Ladle/Remote/DiscoverService.swift`

**Step 1: Write failing refresh-state tests**

Prove first-load skeleton, genuine empty, first-load offline, rate-limited,
successful content, refreshing with retained content, and failed refresh with
stale content plus retry.

**Step 2: Write failing per-item operation tests**

Prove opening and saving expose independent progress and classified errors,
and that an error for one action does not clear the other action's state.

**Step 3: Verify red**

Run `DiscoverViewModelTests`; current `.failed` and string alerts must fail the
new contract.

**Step 4: Implement a data-preserving state**

Keep loaded recipes during refresh, attach `RemoteFailure` to first-load or
refresh failure, and render explicit offline/rate-limit/service states. Saved
Watch remains local and selectable.

**Step 5: Verify and commit**

Run focused tests and relevant UI tests, capture Discover and Watch states,
run `git diff --check`, update the audit record, and commit.

## Task 8: Preserve precise import overload and recovery states

**Files:**

- Modify: `LadleTests/ImportCoordinatorTests.swift`
- Modify: `LadleTests/RemoteImportServiceTests.swift`
- Modify: `Ladle/Import/ImportCoordinator.swift`
- Modify: `Ladle/Import/AddRecipeSheet.swift`
- Modify: `Ladle/Import/FailedImportSheet.swift`
- Modify: `Ladle/Library/PendingImportCard.swift`

**Step 1: Write failing remote-error mapping tests**

Require provider unavailable, quota exhausted, rate limited with retry time,
authentication expiry, and offline transport to remain distinct. Verify the
durable job/link is never lost.

**Step 2: Write failing retry-eligibility tests**

Rate-limited actions remain disabled until the retry time, quota failure
explains when retry is useful, auth expiry directs sign-in, and unsupported or
invalid sources favor manual recovery.

**Step 3: Verify red**

Run the focused import tests. Current default mapping to
`.networkUnavailable` must fail.

**Step 4: Implement precise operation failure state**

Use `RemoteFailure` for transient operation state while preserving stable
`ImportFailure` wire values. Persist only truthful durable failures. Keep
idempotency and the existing exponential status polling bound.

**Step 5: Verify and commit**

Run import, reimport, remote-service, Inbox, and UI recovery tests. Update the
state audit, run `git diff --check`, and commit.

## Task 9: Replace startup crashes with an explicit bootstrap result

**Files:**

- Create: `Ladle/App/AppBootstrap.swift`
- Create: `LadleTests/AppBootstrapTests.swift`
- Modify: `Ladle/App/LadleApp.swift`
- Modify: `Ladle/App/RootView.swift`
- Modify: `project.yml`
- Modify: `Ladle.xcodeproj/project.pbxproj`

**Step 1: Write failing bootstrap tests**

Inject local-store and API-configuration failures and require a blocking
recovery presentation with a diagnostic identifier. Require successful
bootstrap to produce the existing runtime dependencies.

**Step 2: Verify red**

Run `AppBootstrapTests`; the current fatal-error initialization cannot satisfy
the contract.

**Step 3: Implement bootstrap isolation**

Move fallible initialization behind a bootstrap result. Do not manufacture an
empty library after store failure. Offer retry for recoverable store creation;
show a configuration diagnostic for invalid release configuration.

**Step 4: Verify and commit**

Run bootstrap, project smoke, persistence, and full app tests, regenerate the
project, run `git diff --check`, and commit.

## Task 10: Complete secondary-flow state coverage

**Files:**

- Modify: `LadleTests/ShareConfirmationViewTests.swift`
- Modify: `LadleShare/ShareConfirmationView.swift`
- Modify: `LadleShare/ShareViewController.swift`
- Modify: `LadleTests/HealthExportViewModelTests.swift`
- Modify: `Ladle/Health/HealthExportViewModel.swift`
- Modify: `Ladle/Health/HealthExportSheet.swift`
- Modify: `Ladle/Remote/RecipeArtworkView.swift`
- Modify: `Ladle/Library/VideoEmbedSheet.swift`
- Modify: `Ladle/Account/WelcomeView.swift`
- Modify: `Ladle/Account/AccountSheet.swift`

**Step 1: Fix the Share rendering harness red-green**

Add a regression test that balances view appearance transitions and fails on
the current lifecycle warning, then correct the test host cleanup.

**Step 2: Audit state completeness with focused tests**

Add missing tests for Health payload-empty failure, permission denial, offline
write failure, image unavailable/refresh failure, unsupported video URL,
welcome bootstrap failure, account deletion rate limit, and cancellation.

**Step 3: Implement only missing behavior**

Reuse `RemoteFailure` and semantic state components. Keep current final design
and established success flows.

**Step 4: Verify and commit by coherent flow**

Use separate task-sized commits for Share, Health/media, and account changes,
with companion audit updates and `git diff --check` before each.

## Task 11: Finish the semantic design migration

**Files:**

- Modify: `LadleTests/DesignTokenTests.swift`
- Modify: `Ladle/Design/LadleTheme.swift`
- Modify: `Ladle/Design/LadleComponents.swift`
- Modify: app and Share Extension call sites identified by the audit
- Modify: `DESIGN.md`
- Modify: `docs/plans/design-language-migration.md`

**Step 1: Recount and classify every button**

Classify all 122 declarations as semantic action, native menu/dialog action,
navigation/icon control, or row/card interaction. Add tests for reusable
semantic action mappings before changing production call sites.

**Step 2: Replace the legacy primary wrapper**

Move valid call sites to `LadleButtonStyle`, verify focused screens, then
delete `LadlePrimaryButtonStyle` and prove zero references remain.

**Step 3: Complete sheet margins and safe areas**

Write layout tests first, move sheet controls and bodies to
`Layout.sheetMargin`, and replace Watch's fixed top/bottom clearance with real
safe-area input.

**Step 4: Complete typography, control heights, palette roles, and badges**

Migrate raw style values in small screen groups. Preserve values when the
change is semantic only; capture before/after when pixels change.

**Step 5: Remove dead design definitions**

After failing tests prove absence is intended, remove `butter`, compatibility
asset sets (`Field`, `Review`, `Success`, `Paprika`), and any role that remains
unused after migration. Keep `AccentColor` because Xcode consumes it by name.

**Step 6: Verify and commit in batches**

For every batch: focused test red, implementation green, screen capture,
complete `DesignTokenTests`, `git diff --check`, documentation update, and a
task-sized commit.

## Task 12: Perform the repository-wide completion and dead-code pass

**Files:**

- Modify: every file whose audit disposition is incomplete or obsolete
- Modify: `docs/verification/2026-08-26-consolidation-audit.md`
- Create: `.swiftlint.yml` only if the final rules are intentionally adopted

**Step 1: Audit every tracked file by subsystem**

Use `rg --files` and record a disposition for app, Share Extension, LadleCore,
backend, deployment, contracts, assets, tests, plans, and verification docs.

**Step 2: Use authoritative static gates**

Run Swift compilation, backend Ruff/mypy, unused-token searches, target
membership checks, manifest/project regeneration diff, TODO/FIXME searches,
and branch-tree comparisons. Treat raw default SwiftLint as an audit input
until the repository adopts a reviewed configuration.

**Step 3: Remove or complete one coherent subsystem at a time**

Write a failing behavior or structural test before each production change.
Split oversized files only where doing so clarifies distinct ownership; do not
shuffle code merely to satisfy a line threshold.

**Step 4: Reconcile documentation**

Update stale plans to completed/superseded truth. Keep historical verification
records but label invalid assumptions instead of rewriting history.

**Step 5: Verify and commit each subsystem**

Run its narrow tests, `git diff --check`, update the audit ledger, and commit.

## Task 13: Add deterministic state launch scenarios and UI coverage

**Files:**

- Modify: `Ladle/App/LadleApp.swift`
- Modify: `Ladle/Data/PreviewFixtures.swift`
- Modify: `LadleUITests/DiscoverInteractionUITests.swift`
- Create: additional focused UI test files when separation improves clarity

**Step 1: Write failing launch-scenario tests**

Add deterministic launch arguments for empty, offline with recipes, offline
empty, initial store failure, Discover empty, Discover rate limited, import
quota, import rate limit, authentication expiry, and large library.

**Step 2: Verify red**

Run each focused UI test and confirm it fails for the missing scenario rather
than a selector error.

**Step 3: Implement injectable demo services and fixtures**

Keep production dependency behavior unchanged. Centralize scenario parsing so
launch arguments cannot create contradictory states.

**Step 4: Verify green and capture**

Capture Recipes, Discover, Watch, Inbox, Settings, recipe detail, Focus Mode,
welcome, Share Extension, empty, offline, rate-limited, and large-data states
at default, XXX Large, and accessibility Dynamic Type where relevant.

**Step 5: Commit**

Update the audit record, run focused and complete UI tests,
`git diff --check`, and commit.

## Task 14: Run the final release and completion audit

**Files:**

- Modify: `docs/verification/2026-08-26-consolidation-audit.md`
- Modify: `docs/plans/2026-08-26-consolidated-final-design.md`

**Step 1: Run all automated gates**

Run LadleCore, backend Ruff/mypy/unit and relevant integration tests, all app
unit tests, all relevant UI tests, a full app build, a Share Extension build,
and `git diff --check`.

**Step 2: Verify runtime state coverage**

Use the deterministic scenarios and captures to prove every state in the
design document. Confirm local recipes remain usable without connectivity and
that overload/rate limits communicate when retry is possible.

**Step 3: Verify branch consolidation**

For every historical branch, prove its unique capability is present,
superseded, or intentionally excluded. Confirm no useful untracked work remains
only on the MacBook Pro.

**Step 4: Verify repository hygiene**

Confirm no unresolved TODO/FIXME markers, unused tokens/assets, stale target
memberships, unexplained generated diffs, dirty worktrees, or incomplete audit
rows remain.

**Step 5: Commit and push**

Commit the final verification record, push `codex/consolidated-final`, and
leave it clean. Preserve historical branches until the user explicitly
authorizes deletion after reviewing this proof.
