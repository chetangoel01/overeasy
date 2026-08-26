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
The simulator can emit duplicate Apple runtime class warnings. At baseline,
four Share Confirmation rendered tests left unbalanced appearance-transition
warnings, and a generic device build reported a non-Sendable completion
capture in `GoogleSignInProvider`. Task 12 follow-ups resolved both app-owned
warnings. The third-party and Apple-runtime diagnostics remain classified
rather than being treated as app completion evidence.

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

Task 11 removed the unused `Field`, `Review`, `Success`, `Paprika`, and duplicate
`Butter` assets after structural tests proved their absence. `AccentColor` has
no direct source call but is retained because Xcode consumes it by catalog
name.

The Task 11 completion pass reduced numeric production symbol-size calls from
44 to zero, moved the six observed control heights onto three named roles, and
gave the undersized search-clear action a 44-by-44 target. All 17 semantic
surface, label, intent, and stroke roles have live screen consumers. Thirteen
raised-card icon badges now use the distinct badge surface. The baseline table
above remains the fixed before-state rather than being rewritten as work lands.

## State coverage ledger

| Area | Required final states | Status |
| --- | --- | --- |
| Bootstrap | preparing, ready, local-store failure, invalid release configuration | closed in Task 9 |
| Local library | loading, content, true empty, filtered empty, cached-content reload failure, large library | closed in Task 6 |
| Connectivity and sync | current, syncing, offline, degraded, rate limited, quota, expired auth, conflict | closed in Tasks 4-5 and Task 12 follow-up; conflicts preserve the local copy and require an explicit keep-local, use-remote, or accept-remote-deletion choice |
| Discover and remote Watch | initial load, content, empty, content-preserving refresh, stale/offline, classified remote failures, per-item operation | closed in Task 7 |
| Imports | validation, duplicate, guest limit, queued, processing, review, completion, cancellation, concurrency, classified recovery | closed in Task 8 |
| Secondary flows | account, health, image, video, editor, timer, Share handoff, destructive actions | closed in Task 10; missing Health/media/account states added without regressing established editor, timer, Share, or destructive-action behavior |
| Deterministic launch scenarios | empty, offline, failure, overload, expired auth, large data | closed in Task 13 with ten named state scenarios and default, XXX Large, and accessibility-size captures |

## Design and cleanup ledger

| Area | Completion criterion | Status |
| --- | --- | --- |
| Historical capability integration | guarded tunnel and bounded worker verified on current base | closed in Tasks 2-3 |
| Semantic components | every button and compatibility style classified; valid call sites migrated | closed in Task 11: 126 controls classified, legacy wrapper removed, ordinary semantic actions use explicit roles, and provider/Focus/inline/native exceptions are recorded |
| Layout and safe areas | sheet margins and Watch safe-area behavior use approved semantics | closed in Task 11: 11 sheet toolbars aligned and Watch consumes live safe-area insets |
| Typography and controls | raw typography/control values are intentional or semantic | closed in Task 11: numeric symbol sizes eliminated, interactive heights named, and remaining fixed geometry classified as layout/provider art |
| Palette and assets | every role/asset has a live consumer or is removed | closed in Task 11: raw palette calls confined to theme definitions, all 17 roles have live consumers, and five dead compatibility assets were removed |
| Production source | every file and declaration has a live responsibility | closed in Task 12: every source path is target-owned and compiled; focused symbol/asset searches found no orphaned production implementation |
| Tests and fixtures | every fixture is used and every scenario is deterministic | closed in Tasks 12-13: fixtures are consumed by demo/runtime tests and one scenario enum owns every whole-app substitution |
| Config and targets | manifests regenerate cleanly; target memberships are intentional | closed in Task 12: XcodeGen reproduces the checked-in project and all three new scenario files have exactly one intended source membership |
| Documentation | plans and verification records reflect current behavior or are marked historical | closed in Task 12: current root/product/design references agree that Ladle is the internal project name and Overeasy is the shipped product name; dated records remain historical evidence |

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

### Explicit sync conflict resolution

The Task 12 follow-up completes the one open connectivity state. A sync run
now returns its persisted conflict count, so a completed run with unresolved
recipes reports “Review changes” instead of “Up to date.” Library snapshots
publish the conflict records without replacing the local recipe. A compact
banner opens a dedicated review sheet that names the on-device and
other-device versions and explains that the saved local copy remains safe.

Resolution is deliberately asymmetric and explicit:

- “Keep My Version” clears the conflict only after advancing the mutation's
  base revision, allowing the next coalesced sync to retry against the current
  server version;
- “Use Other Version” replaces the local draft, clears its pending mutation,
  and adopts the remote revision;
- a remote deletion is shown as “Deleted on another device” and removes the
  local copy only through the destructive “Remove Local Copy” action.

Verification on August 26, 2026:

- focused tests first failed on the absent state, repository resolution APIs,
  view-model publication, and review presentation copy;
- 54 focused status, sync-service, persistence, library, and presentation
  tests passed after the initial implementation;
- the complete `LadleTests` target executed 245 tests: 244 passed and the one
  live App Attest test was intentionally skipped;
- XcodeGen added the dedicated review source to the app target, and the
  checked-in project otherwise remained reproducible;
- the complete test log contains no unbalanced Share lifecycle warning; the
  only diagnostics after the source-warning correction are Xcode's
  AppIntents metadata skips.

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

### Balanced Share rendering harness

The first Task 10 checkpoint traced four unbalanced appearance-transition
warnings to the four rendered Share Confirmation tests. Their temporary
windows were hidden while still retaining their hosting controllers, so UIKit
began disappearance during suite teardown without completing it. The shared
teardown now detaches the root controller before hiding the window. The
renderer also constructs windows from the active `UIWindowScene`, removing
the iOS 26 `UIWindow(frame:)` deprecation.

Verification on August 26, 2026:

- the new lifecycle regression test failed because the root controller
  remained attached, proving the red state;
- all 7 `ShareConfirmationViewTests` passed after the one-line lifecycle fix;
- the complete non-quiet test log contains no unbalanced appearance-transition
  warning, compared with exactly four before the fix;
- the final focused run emitted neither the lifecycle warning nor the
  deprecated-window warning.

A later complete-suite run showed that detaching before hiding only moved the
UIKit warning beyond the Share suite boundary. Task 12 completed the repair:
the harness now makes a scene-backed window visible without taking key-window
status, gives UIKit a run-loop turn to finish appearance before capture, then
hides and flushes the window before detaching the host. A lifecycle spy guards
the appearance and disappearance-start boundaries.

Follow-up verification on August 26, 2026:

- all 7 focused `ShareConfirmationViewTests` passed;
- the complete `LadleTests` target executed 239 tests: 238 passed and the one
  live App Attest test was intentionally skipped;
- the complete raw test log contains no warning and no unbalanced
  appearance-transition message, including after `ShareURLExtractorTests`.

### Sendable Google Sign-In prewarm callback

Task 12 marked the injected App Check completion as `@Sendable`, matching the
Google SDK callback that captures it. This removes the only app-source compiler
warning without changing the best-effort prewarm behavior.

Verification on August 26, 2026:

- a structural regression test failed on the missing sendability annotation;
- the existing failure-tolerant prewarm test and the new annotation test pass;
- the focused non-quiet build log contains no Google Sign-In sendability
  warning, compared with the repeated warning in the Task 11 generic build.

### Health and media failure states

The second Task 10 checkpoint makes secondary media failures explicit without
disturbing successful content. Apple Health now distinguishes an immutable
empty-nutrition payload from permission denial, offline write failure, and an
ordinary write failure. Empty payloads never request permission and do not
offer a retry that cannot change the recipe. Denial writes nothing, while
offline and other transient write failures preserve the export action for a
truthful retry.

Remote artwork shows separate placeholder, loading, loaded, and unavailable
presentations. The cache preserves the initial HTTP status, refreshes an
expired signed URL only once, and reports when the refreshed recipe no longer
contains the requested image. Unsupported or malformed video links continue
to stay inside Overeasy and now share one tested unavailable title and message
instead of relying on duplicated inline copy.

Verification on August 26, 2026:

- the focused build failed on the missing typed Health failure, artwork state,
  and video unavailable contract, proving the red state;
- 23 focused Health, image-cache, artwork-presentation, and video-navigation
  tests passed;
- image tests cover a 404 response and a failed expired-URL refresh in addition
  to the successful refresh and cache-hit paths;
- the complete `LadleTests` target passed 224 tests: 223 passed and the one
  live App Attest test was intentionally skipped.

### Recoverable account entry and deletion

The final Task 10 checkpoint gives welcome authentication and account deletion
typed failure states. Welcome now distinguishes offline transport, temporary
service failure, an exact server rate-limit time, quota, expired
authentication, malformed responses, missing Google configuration, and an
ordinary provider failure. User and task cancellation remain silent instead
of appearing as errors.

A failed deletion no longer implies that local state may have changed. Its
alert states that the account and recipes are unchanged, classifies the same
remote failures, and preserves an exact rate-limit retry time. Sign-out and
deletion controls are mutually disabled while either destructive operation is
running. `AuthClient` already cleared credentials only after a successful
server response; the new regression test proves a rate-limited deletion keeps
both the original token and signed-in account state.

Verification on August 26, 2026:

- the focused build first failed because the typed welcome and deletion
  failures did not exist, proving the red contract;
- all welcome/account smoke, `AuthClientTests`, and `AccountSessionTests`
  passed;
- the complete `LadleTests` target passed 227 tests: 226 passed and the one
  live App Attest test was intentionally skipped;
- the focused Settings navigation UI test passed through the updated account
  presentation.

## Repository-wide completion pass

Task 12 classified every tracked path rather than treating line count or a
default linter profile as a deletion instruction. The final inventory contains
612 tracked files after the three deterministic-scenario files are added:

| Subsystem | Exact path scope | Files | Disposition and evidence |
| --- | --- | ---: | --- |
| App source | `Ladle/**` except `Ladle/Resources/**` | 76 | owned by the Ladle target; complete app build and unit suite compile every file |
| App assets and resources | `Ladle/Resources/**` | 32 | all named image sets have source consumers; `AppIcon` and `AccentColor` are Xcode-consumed; privacy manifest parses |
| App configuration | `Config/**` | 8 | plist/privacy syntax passes; build settings and entitlements are consumed by declared targets |
| App tests | `LadleTests/**` | 28 | owned by `LadleTests`; complete suite is a final release gate |
| UI tests | `LadleUITests/**` | 2 | owned by `LadleUITests`; both interaction and deterministic state suites execute |
| Share Extension | `LadleShare/**` | 3 | owned by `LadleShare`; direct build and embedded-product checks are release gates |
| LadleCore source | `Packages/LadleCore/Sources/**` | 14 | owned by the package target; 45 tests pass |
| LadleCore tests | `Packages/LadleCore/Tests/**` | 9 | all discovered by SwiftPM |
| LadleCore support | other `Packages/LadleCore/**` | 1 | package manifest parses and resolves |
| Backend source | `Backend/ladle/**` | 121 | authoritative mypy checks all 121 files; Ruff and pytest cover the package |
| Backend tests | `Backend/tests/**` | 113 | 613 selected unit tests pass at baseline; final rerun remains a release gate |
| Backend documentation | `Backend/docs/**` | 48 | current integration/deployment references retained; dated records are evidence, not live configuration |
| Backend migrations | `Backend/alembic/**`, `Backend/alembic.ini` | 17 | migration graph and contract tests retain every revision |
| Deployment and operations | `Backend/deploy/**`, `Backend/scripts/**`, `Backend/systemd/**` | 38 | shell syntax, deployment tests, and Compose rendering cover the scripts and units |
| Backend manifests/support | remaining `Backend/**` | 32 | Compose, container, environment, dependency, and tool manifests are consumed by CI/local workflows |
| Contracts | `Contracts/**` | 8 | shared JSON examples/schemas parse and backend contract tests consume them |
| Generated project/manifest | `Ladle.xcodeproj/**`, `project.yml`, `Package.resolved` | 5 | clean XcodeGen reproduction; checked-in workspace SwiftPM directory is intentional |
| Plans | `docs/plans/**` | 22 | dated design/implementation history retained; current consolidation plan owns open work |
| Verification | `docs/verification/**` | 25 | dated immutable evidence retained; this ledger is the current truth surface |
| Other documentation | other `docs/**` | 3 | current handoff, privacy, and backend design references retained |
| Repository support/root | root files and `.github/**` | 7 | README, product/design contracts, instructions, ignore rules, and CI/dependency workflows are live |

Authoritative static results on August 26, 2026:

- every tracked shell script passes `bash -n`, every tracked JSON file passes
  `jq empty`, and every tracked plist/privacy manifest passes `plutil -lint`;
- Ruff passes the entire backend, and mypy passes all 121 files under
  `Backend/ladle`;
- regenerating the project in a temporary copy with XcodeGen 2.46.0 produces
  the checked-in `project.pbxproj` byte-for-byte; the scenario source, unit
  test, and UI test each have one intended source membership;
- `swift test --package-path Packages/LadleCore` passes 45 tests in 9 suites;
- no production TODO, FIXME, HACK, or XXX marker remains; the only deliberate
  crash guards are three `preconditionFailure` calls in deterministic preview
  fixture construction;
- no named image set is orphaned, and the five earlier compatibility assets
  remain removed;
- Periphery and Lychee are not installed. The unused-code audit therefore uses
  compiler target ownership, tests, asset-reference searches, and focused
  declaration searches rather than claiming output from unavailable tools.

The tracked-Swift-only default SwiftLint audit reports 285 findings: 107
trailing commas, 31 type-body length, 26 file length, 22 closure-parameter
position, 21 force-try, 20 function-body length, 20 opening-brace, 11 line
length, and smaller default-style groups. Production "errors" are 18 size or
large-tuple thresholds in cohesive views/coordinators; force operations are
primarily deterministic test construction. These unreviewed defaults conflict
with the repository's established format, so no `.swiftlint.yml` is adopted
merely to suppress them. SwiftLint remains an audit input, not a release gate.

## Deterministic launch scenarios

Task 13 adds one test-only `DemoLaunchScenario` parser. Production launches
ignore it. Exactly one `-demo-scenario <name>` can select empty, offline with
content, offline empty, store failure, Discover empty, Discover rate limiting,
import quota, import rate limiting, authentication expiry, or an 80-recipe
library. Unknown, duplicated, legacy-plus-new, or otherwise contradictory
arguments fall back to the standard demo. The legacy `-empty-library` switch
remains compatible.

The initial focused build failed because the parser and runtime hook did not
exist, proving the red state. Four parser/configuration unit tests then passed.
The final `StateScenarioUITests` run executed 13 tests with zero failures and
retained captures for all ten named state families plus:

- Inbox, recipe detail, Full Recipe cooking, and Focus Mode in one real
  navigation journey;
- the 80-recipe library at default size and XXX Large, where the grid becomes
  a single readable column;
- welcome at accessibility XXX Large, with the guest path still present;
- explicit offline content preservation, offline empty, initial store failure,
  Discover empty/rate-limited, import quota/rate-limited, and expired-session
  surfaces.

Existing interaction coverage retains default-size captures for Recipes grid
and list, Discover, Watch, Settings, import recovery, and destructive recipe
actions. The seven Share confirmation renderer tests cover the extension
states with balanced UIKit appearance lifecycle.

At the Task 13 checkpoint, the complete `LadleUITests` target passed all 21
tests, and the complete `LadleTests` target executed 249 tests: 248 passed and
the one live App Attest test was intentionally skipped. The test logs contain
only Apple simulator/runtime and AppIntents metadata diagnostics, not app
source warnings or Share lifecycle imbalance.

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
