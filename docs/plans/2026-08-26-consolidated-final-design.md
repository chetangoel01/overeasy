# Consolidated Final Design

**Status:** approved implementation direction

## Purpose

Consolidate every still-valid capability from the repository's historical
branches into one releasable branch, preserve the approved Porcelain &
Graphite interface, finish incomplete behavior, and make every meaningful
application state explicit and testable.

The final branch is `codex/consolidated-final`, based on
`codex/notifications-preferences-discover-grid` at `b262862`. Historical
branches remain recoverable until this branch completes the full verification
gate.

## Consolidation policy

Branch work is integrated by user-visible capability, not by mechanically
merging every historical commit. This prevents obsolete build metadata,
superseded styling, and duplicate implementations from returning.

| Source | Disposition |
| --- | --- |
| `codex/notifications-preferences-discover-grid` | Base branch and final visual design |
| `codex/guarded-device-tunnel` | Integrate guarded device tunnel and its local Docker reliability prerequisite |
| `codex/local-docker-reliability` | Covered by the guarded-device-tunnel integration; do not apply twice |
| `codex/testflight-20260823-3` | Superseded by build `20260825.2`; preserve historical verification only when still accurate |
| `codex/iphone-deploy-2026-07-29` | Asset scale slots are already present in the base tree |
| Remaining feature branches | Already ancestors of the base tree; verify their behavior through the final test matrix |

The untracked ingredient-art comparison board is research, not an approved
product surface. It uses externally hosted evaluation assets and remains
outside the release branch.

## Product and visual authority

`PRODUCT.md` and `DESIGN.md` are authoritative. The existing native SwiftUI
design is final:

- Porcelain library surfaces and graphite cooking/watch surfaces stay.
- Food photography leads; accent color indicates action or state only.
- Native navigation, controls, safe areas, Dynamic Type, VoiceOver, Reduce
  Motion, and 44-point targets remain non-negotiable.
- New state and recovery UI reuses semantic tokens and component roles. It
  does not introduce another visual direction.
- Existing spacing, typography, and button migrations are completed instead
  of retaining compatibility wrappers indefinitely.

## State architecture

Local content and remote availability are separate concerns. A failed sync or
network request must never turn an existing local library into an empty state.

### Bootstrap

The app distinguishes:

- preparing the local store;
- ready;
- recoverable local-store failure with a retry path;
- invalid release configuration, which presents a blocking diagnostic rather
  than crashing without context.

### Local library

The library distinguishes:

- initial load;
- loaded with recipes;
- a genuinely empty library;
- search or filters with no matches;
- local persistence failure while preserving the last known in-memory data;
- large collections rendered lazily and deterministically.

Recipes, saved Watch content, cooking, editing, and the Inbox remain available
offline because their source of truth is the local repository.

### Connectivity and sync

Remote availability has a shared presentation model:

- online and current;
- synchronizing;
- offline, with local data still available;
- temporarily degraded or server unavailable;
- rate-limited until a known retry time;
- quota exhausted;
- authentication expired;
- sync conflict requiring user resolution.

Reachability is a hint, while actual request results are authoritative. Sync
runs remain coalesced, preserve pending local mutations, and expose status
instead of discarding errors.

### Remote-only surfaces

Discover and its Watch feed distinguish:

- first load with skeleton content;
- loaded content;
- genuine empty results;
- refresh in progress while keeping current content visible;
- offline with an explicit retry path;
- stale content after a failed refresh;
- rate limit, quota, authentication, and server failures;
- per-recipe opening and saving progress or failure.

Saved Watch recipes remain available when Discover is unavailable.

### Imports

Imports distinguish validation, duplicate detection, guest limits, durable
queueing, foreground and background processing, review, completion,
cancellation, and concurrent-operation protection. Failures preserve the link
and map remote error codes precisely:

- no connection;
- provider temporarily unavailable;
- rate limit with retry time;
- processing quota exhausted;
- authentication expired;
- invalid or unsupported source;
- insufficient source evidence;
- local persistence failure.

Retry is offered only when it can succeed. Manual recovery remains available
when the provider cannot supply enough evidence.

### Secondary flows

Account, health export, image loading, video embedding, editing, timers, Share
Extension handoff, and destructive actions each retain explicit loading,
success, empty or unavailable, error, cancellation, and retry states where the
operation supports them.

## Capacity and overload

The backend enforces bounded worker concurrency and resource limits for local
Docker operation. The guarded tunnel exposes only its loopback edge and
requires a per-build key. Client requests preserve idempotency, coalesce sync,
cancel obsolete work, and honor server rate-limit timing. Large local
libraries use lazy views; sync continues to consume bounded pages.

## Cleanup policy

Every production, test, configuration, asset, and documentation file is
audited against a live call site, target, manifest, or explicit historical
purpose. The pass removes or completes:

- unused design tokens and asset sets;
- compatibility wrappers whose call sites can use semantic components;
- dead declarations, unreachable branches, stale fixtures, and misleading
  comments;
- swallowed errors that affect user-visible state;
- incomplete design-language migration work;
- oversized mixed-responsibility files when extraction materially clarifies
  ownership;
- obsolete plan statements and verification records that contradict current
  behavior.

Line count is reduced only when clarity, correctness, accessibility, and test
coverage are preserved.

## Verification contract

Each behavior change follows red-green-refactor and receives a companion
record. The final gate includes:

- `swift test --package-path Packages/LadleCore`;
- backend Ruff, strict mypy, unit tests, relevant integration tests, and local
  Docker profile tests;
- focused app unit and UI tests for every added state;
- complete `LadleTests` and relevant `LadleUITests` runs;
- full Ladle app and Share Extension builds;
- light, dark, large Dynamic Type, accessibility Dynamic Type, VoiceOver,
  Reduce Motion, empty, offline, rate-limited, and large-data captures;
- `git diff --check` before every task-sized commit;
- a requirement-by-requirement audit proving every historical branch and
  explicit product state has a final disposition.

