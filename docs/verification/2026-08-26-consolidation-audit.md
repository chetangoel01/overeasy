# Consolidation Audit

**Branch:** `codex/consolidated-final`

**Base:** `codex/notifications-preferences-discover-grid` at `b262862`

**Started:** August 26, 2026

**Status:** in progress

## Completion rule

This ledger is the proof surface for the final consolidation. A row may be
closed only with a commit, test, source comparison, or explicit product
decision. Historical branches remain intact until every row is closed and the
user separately authorizes branch deletion.

## Machine and repository inventory

The active implementation worktree is on **Chetan's Mac mini** at:

```text
/Users/chetangoel/Documents/recipe-app/.worktrees/consolidated-final
```

The MacBook Pro was queried over SSH on August 26, 2026. Its two repositories
had these states:

| MacBook Pro repository | State | Unique untracked work |
| --- | --- | --- |
| `~/Desktop/Repositories/recipe-app` | `main` ahead of `origin/main` by 3; all tracked commits mirrored locally | `design/board/ingredient-icon-directions.html` |
| `~/Documents/recipe-app` | clean `main`; all tracked commits mirrored locally | none |

The comparison board is unapproved visual research containing externally
hosted evaluation art. It is deliberately excluded from the release branch;
the approved Porcelain & Graphite direction in `DESIGN.md` remains final.

Every MacBook branch tip exists as a local branch and as a
`macbook-desktop/*` or `macbook-documents/*` tracking ref. Every historical
local branch is checked out in its own clean worktree on the Mac mini. There
is therefore no tracked implementation that exists only on the MacBook Pro.

## Branch disposition

The divergence column is `base-only / branch-only` commit count relative to
`b262862`. A branch-only count of zero proves the base contains the branch.

| Branch | Tip | Divergence | Disposition | Proof |
| --- | --- | ---: | --- | --- |
| `codex/notifications-preferences-discover-grid` | `b262862` | `0 / 0` | consolidation base; approved final design | source-identical starting tree |
| `codex/guarded-device-tunnel` | `fa34486` | `84 / 3` | port current guarded tunnel and Docker prerequisite | ported and verified in Tasks 2-3, closed |
| `codex/local-docker-reliability` | `6b2268b` | `84 / 2` | capability is a strict subset of guarded tunnel history | ported and verified in Task 2, closed |
| `codex/testflight-20260823-3` | `0cba6e7` | `84 / 2` | exclude obsolete `20260823.3` build bump; current base is `20260825.2` | version comparison, closed |
| `codex/iphone-deploy-2026-07-29` | `8ba1908` | `211 / 1` | scale-slot declaration already present in base assets | asset comparison, closed |
| `codex/inline-watch-video-demo` | `cab67cc` | `35 / 0` | contained in base | ancestry check, closed |
| `codex/ladle-v1` | `a89d48b` | `366 / 0` | contained in base | ancestry check, closed |
| `codex/library-interaction-polish` | `f863bf1` | `201 / 0` | contained in base | ancestry check, closed |
| `codex/visual-direction-refresh` | `1e79457` | `356 / 0` | contained in base | ancestry check, closed |
| `codex/vps-live-provider` | `e41de52` | `140 / 0` | contained in base | ancestry check, closed |
| `codex/watch-full-screen-feed` | `9820121` | `85 / 0` | contained in base | ancestry check, closed |
| `codex/wip-handoff-2026-08-02` | `65fb8fa` | `132 / 0` | contained in base | ancestry check, closed |

Unique commits requiring a decision:

```text
fa34486 feat: add guarded local device tunnel
6b2268b docs: record live Docker import verification
a2787d4 fix: keep local Docker worker healthy
0cba6e7 docs: record TestFlight upload
97c5284 chore: prepare TestFlight build 20260823.3
8ba1908 chore: declare asset catalog scale slots
```

## Baseline verification

The code baseline is unchanged from `b262862`; the two consolidation commits
before this record contain documentation only.

| Gate | Result on August 26, 2026 |
| --- | --- |
| `swift test --package-path Packages/LadleCore` | passed, 45 tests in 9 suites |
| Backend Ruff | passed |
| Backend mypy | passed, 121 source files |
| Backend tests excluding integration, chaos, and live-provider markers | passed, 613 tests; 84 deselected |
| `LadleTests` on iOS 26.5 simulator | passed, 195 tests; 1 intentional live App Attest skip |

The backend run emits one third-party `testcontainers` deprecation warning.
The simulator emits duplicate AuthKit class warnings. Four Share Confirmation
rendered tests leave unbalanced appearance-transition warnings after they
pass. A generic device build reports a non-Sendable completion capture in
`GoogleSignInProvider`. Those warnings are baseline debt, not ignored
completion evidence.

## Baseline completion signals

These are audit inputs rather than arbitrary cleanup targets:

| Signal | Baseline |
| --- | ---: |
| Swift production lines across app, extension, and LadleCore sources | 19,729 |
| Swift files over 400 lines | 19 |
| largest file, `ImportCoordinator.swift` | 822 lines |
| Button declarations | 122 |
| `LadlePrimaryButtonStyle` symbol references | 34 |
| direct `LadleButtonStyle` symbol references | 5 |
| raw `.font(.system(size:))` calls | 44 |
| raw frame-height signals | 75 |
| semantic `Surface` calls | 56 |
| semantic `Label` calls | 58 |
| semantic `Intent` calls | 14 |
| semantic `Layout` calls | 68 |
| semantic `Control` calls | 1 |
| semantic `IconSize` calls | 2 |

The unconfigured default SwiftLint run reported 282 violations. Ninety-three
are trailing-comma findings and many length/style findings conflict with the
repository's current conventions. Three TODO findings were generated SwiftPM
runner code under `.build`, not repository source. SwiftLint is not a project
gate until a reviewed configuration is deliberately adopted.

Current asset candidates with no direct source call are `Field`, `Review`,
`Success`, and `Paprika`. `Butter` has one compatibility reference in
`LadleTheme`. `AccentColor` has no direct source call but is retained because
Xcode consumes it by catalog name.

## State coverage ledger

| Area | Required final states | Status |
| --- | --- | --- |
| Bootstrap | preparing, ready, local-store failure, invalid release configuration | closed in Task 9 |
| Local library | loading, content, true empty, filtered empty, cached-content reload failure, large library | closed in Task 6 |
| Connectivity and sync | current, syncing, offline, degraded, rate limited, quota, expired auth, conflict | shared failure vocabulary and observable status closed in Tasks 4-5; conflict handling remains open |
| Discover and remote Watch | initial load, content, empty, content-preserving refresh, stale/offline, classified remote failures, per-item operation | closed in Task 7 |
| Imports | validation, duplicate, guest limit, queued, processing, review, completion, cancellation, concurrency, classified recovery | closed in Task 8 |
| Secondary flows | account, health, image, video, editor, timer, Share handoff, destructive actions | open, Task 10 |
| Deterministic launch scenarios | empty, offline, failure, overload, expired auth, large data | open, Task 13 |

## Design and cleanup ledger

| Area | Completion criterion | Status |
| --- | --- | --- |
| Historical capability integration | guarded tunnel and bounded worker verified on current base | closed in Tasks 2-3 |
| Semantic components | every button and compatibility style classified; valid call sites migrated | open, Task 11 |
| Layout and safe areas | sheet margins and Watch safe-area behavior use approved semantics | open, Task 11 |
| Typography and controls | raw typography/control values are intentional or semantic | open, Task 11 |
| Palette and assets | every role/asset has a live consumer or is removed | open, Task 11 |
| Production source | every file and declaration has a live responsibility | open, Task 12 |
| Tests and fixtures | every fixture is used and every scenario is deterministic | open, Tasks 12-13 |
| Config and targets | manifests regenerate cleanly; target memberships are intentional | open, Tasks 12-14 |
| Documentation | plans and verification records reflect current behavior or are marked historical | open, Tasks 12-14 |

## Completed state foundations

### Shared remote failure vocabulary

Task 4 added one typed mapping for offline transport, provider/server outage,
rate limiting with its retry time, quota exhaustion, authentication expiry,
invalid responses, and unknown failures. Titles, messages, and retry policy are
stable and server messages do not enter primary user copy. A separate report
retains the server request ID for diagnostics.

Verification on August 26, 2026:

- 4 `RemoteFailureTests` passed after the missing-type compile failure proved
  the red state;
- 7 `APIClientTests` passed;
- 18 `ProjectSmokeTests` passed;
- XcodeGen regenerated the checked-in project with both new Swift files.

### Observable sync and connectivity

Task 5 added a single observable status model for every app-level sync trigger.
The model records idle, in-progress, current, and classified failure states
while preserving the last successful sync time. Local library content remains
visible during remote failures: a compact workspace banner explains offline,
service, rate-limit, quota, authentication, response, and unknown failures,
and Settings now reports that same live state instead of a static "On" value.
Signing out or deleting an account resets the status.

All startup, foreground, authentication, import, and local-mutation sync calls
now pass through one helper. A source search found no remaining silent
`try? await syncService` call; cancellation is handled separately from failure,
and later success clears an earlier error.

Verification on August 26, 2026:

- the initial focused build failed because `SyncStatus` did not exist, proving
  the state-model red test;
- the account-presentation test then failed to compile until it received the
  new live status, proving the integration red test;
- 4 `SyncStatusTests` plus focused Account and root-view smoke tests passed;
- the complete `LadleTests` target passed 203 tests: 202 passed and the one
  live App Attest test was intentionally skipped;
- XcodeGen regenerated the checked-in project with the new source and test.

### Local snapshot and reload semantics

Task 6 separates a failed first read from a failed refresh. Until the local
repository returns one complete recipes-and-imports snapshot, the workspace
shows one blocking load or retry surface and constructs none of its four tabs.
This prevents Inbox and saved Watch from presenting false empty states when the
store is unavailable. Settings remains reachable; add/import actions remain
hidden until the first snapshot succeeds.

After a successful snapshot, a later repository error preserves recipes,
imports, Watch ordering, and the known-empty case. The workspace remains fully
usable and shows a compact inline "Showing saved recipes" message with a retry
action. A successful retry atomically replaces both arrays and clears the
message. The existing true-empty and filtered-empty presentations remain
distinct. The centralized workspace gate made duplicate changes inside
`ImportInboxView` and `WatchView` unnecessary.

Verification on August 26, 2026:

- focused tests first failed because the new snapshot error and workspace
  presentation did not exist, proving the red state;
- 42 `LibraryViewModelTests` and `LibraryNavigationStateTests` passed;
- a deterministic 1,000-recipe test covered exact search, cooking-time sort,
  favorite/time filters, collection counts, and stable Watch ordering;
- `AllRecipesView` retains `LazyVGrid`/`LazyVStack`, and `WatchView` retains
  `LazyVStack`; no eager large-data container was added;
- the complete `LadleTests` target passed 207 tests: 206 passed and the one
  live App Attest test was intentionally skipped.

### Discover and remote Watch resilience

Task 7 separates Discover's first load from subsequent refreshes. A first load
uses the existing skeleton, then produces content, a genuine empty state, or a
typed offline/service/rate-limit/quota/authentication/response failure. Once
content has loaded, refresh leaves it in place and exposes an independent
refreshing, stale-failure, or current status. A later success replaces the
stale results and clears the refresh message.

Opening and saving are tracked independently for each Discover recipe. Both
the list and Watch show their own progress and classified inline errors; a
save result never clears an open error and an open result never clears a save
error. Watch also keeps its local "My Recipes" feed selectable through every
remote state. `RemoteDiscoverService` required no translation change because
it already propagates `APIError` intact to the view model.

Verification on August 26, 2026:

- focused tests first failed on the missing associated failure, refresh, and
  per-operation state, proving the red contract;
- all 11 `DiscoverViewModelTests` passed, including suspended in-flight checks
  for independent open/save progress;
- first-load offline, provider-unavailable, and rate-limited failures were
  classified, including the exact retry time;
- 3 focused `DiscoverInteractionUITests` passed for Discover interaction,
  Watch paging, and switching between saved and remote feeds;
- the test result contains reviewed "Discover loaded results" and "Watch
  full-screen feed" screenshots at 1,206 by 2,622 pixels;
- the complete `LadleTests` target passed 211 tests: 210 passed and the one
  live App Attest test was intentionally skipped.

### Precise import overload and recovery

Task 8 preserves the exact transient cause of an import failure without
changing the stable `ImportFailure` persistence vocabulary. Provider outage,
quota exhaustion, rate limiting with its server-supplied retry date,
authentication expiry, and offline transport now remain distinct in the
active coordinator and across the add, Inbox-card, and failed-import
surfaces. Their durable mappings stay truthful and compatible: rate and quota
persist as capacity exhaustion, provider failure as parser unavailability,
offline as network unavailability, and authentication expiry unchanged.

Every failed admission job is saved before the failure is exposed, so its
original source URL and recovery path survive. Rate-limited retry remains
disabled until the exact retry date and updates while the failure view is
open. Quota and authentication failures explain their prerequisites, while
invalid and unsupported links favor correction, pasted details, or manual
entry. Existing idempotency keys, bounded status polling, cancellation, and
reimport replacement safeguards were not weakened.

Verification on August 26, 2026:

- the focused tests first failed on the missing precise operation-failure
  state, proving the red contract;
- 24 focused coordinator, remote-service, and recovery-copy tests passed;
- 67 adjacent reimport, demo service, library, shared-queue, and smoke tests
  passed;
- 2 focused UI tests passed for dismissible background processing and the
  failed-import recovery actions;
- the complete `LadleTests` target passed 214 tests: 213 passed and the one
  live App Attest test was intentionally skipped;
- a final 20-test coordinator and UI check passed after adding the live
  retry-date transition.

### Explicit startup bootstrap

Task 9 removes both production `fatalError` startup paths. App construction
now begins with a visible preparing state and creates the SwiftData store,
release service configuration, and existing runtime dependency graph behind a
single bootstrap result. The ready result preserves the previous account,
queue reconciliation, notification, import, Discover, sync, image-cache, and
scene lifecycle behavior.

A local-store failure never constructs a replacement repository or presents a
false empty library. It blocks the workspace, states that the library was not
cleared, exposes diagnostic `OE-BOOT-STORE-001`, and retries the same real
bootstrap. Invalid live API configuration blocks startup with diagnostic
`OE-BOOT-CONFIG-001` and directs the user to a valid build rather than offering
a retry that cannot succeed. Both failure surfaces use the approved semantic
theme and expose stable accessibility identifiers for deterministic scenarios.

Verification on August 26, 2026:

- the initial focused build failed because `AppBootstrap` did not exist,
  proving the red contract;
- 4 `AppBootstrapTests` passed for store failure, invalid configuration,
  complete ready dependencies, and a failure-then-success retry;
- 45 focused bootstrap, project-smoke, persistence, shared-queue, and account
  tests passed;
- the complete `LadleTests` target passed 218 tests: 217 passed and the one
  live App Attest test was intentionally skipped;
- a generic simulator build passed for the Ladle app and embedded Share
  Extension;
- the Settings navigation UI test launched through the new bootstrap and
  passed;
- a production-source search found no remaining `fatalError` call.

## Final release gates

- [ ] LadleCore tests
- [ ] Backend Ruff
- [ ] Backend mypy
- [ ] Backend unit tests
- [ ] Relevant backend integration and deployment tests
- [ ] Complete `LadleTests`
- [ ] Relevant `LadleUITests`
- [ ] Ladle app build
- [ ] Share Extension build
- [ ] Deterministic state captures across required appearance/accessibility modes
- [ ] Repository-wide dead/incomplete-code audit closed
- [ ] Branch consolidation table closed
- [ ] MacBook Pro rechecked for new tracked or untracked work
- [ ] `git diff --check`
- [ ] Clean pushed `codex/consolidated-final`
