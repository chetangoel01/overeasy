# Ladle (ships as **Overeasy**)

Ladle — shipping under the product name **Overeasy** — is a native iPhone recipe workspace for turning scattered social-video
links into structured recipes that are easier to save, review, and cook.

The app follows the Porcelain & Graphite system: cool neutral surfaces let food
photography lead, graphite supports high-contrast cooking, and signal red is
reserved for actions and attention. It is implemented in SwiftUI with a
SwiftData persistence layer and a separate `LadleCore` domain package.

## What is included

- Guest onboarding with an explicit ten-recipe limit
- Link, manual-entry, and iOS Share Extension import entry points
- Durable Share Extension queue reconciliation through an App Group
- Parsing, exceptional check-details, ready, duplicate, and recoverable failure
  states
- Discover from aggregate saves of public recipe-video sources, with permanent
  account-level suppression after a source has been saved
- Full-screen Watch with remembered My Recipes/Discover segments, inline
  TikTok, Instagram, and YouTube playback, native pause and mute controls,
  creator attribution, and vertical paging
- A durable Import Inbox that can reopen active processing, confirm true
  cancellation, discard terminal exceptions, and stay quiet after success
- Search, sorting, filters, aligned compact Grid, List, image-first Gallery,
  and favorites
- A persistent user-selected accent color in Settings
- Structured recipe detail, editing, and safe re-import
- Per-serving calories and protein in library surfaces, a complete macro strip
  on recipe detail, and full macro/micronutrient drill-down with estimates
  labeled only when values are estimated
- Explicit, review-first Apple Health nutrition export
- Full Recipe and Focus cooking modes with shared completion state
- Detected timers, local timer notifications, and opt-in keep-awake behavior
- Ready-only import completion notifications requested in context; tapping one
  opens the completed recipe directly
- Dynamic Type layouts, Reduce Motion behavior, semantic controls, and
  44-point primary hit regions

## Current product boundary

The native app is connected to the FastAPI backend through real guest, Apple,
and Google authentication, remote import polling, discovery, and offline-first
recipe synchronization. The live worker uses free source metadata and
transcripts first, then server-side media download and Whisper transcription,
optional frame analysis, paid transcript fallbacks, and structured extraction
through the configured model provider.

`DemoImportService` remains available only through explicit demo/test
injection. Local Docker Compose inherits provider credentials from
`Backend/.env`; without them it defaults to deterministic fake providers while
still exercising the API, worker queue, PostgreSQL, shared extraction cache,
and object storage.

## Project layout

```text
Ladle/                  SwiftUI application
  Account/              Welcome and guest/account state
  App/                  App entry point and root composition
  Cooking/              Full Recipe, Focus mode, timers, keep-awake
  Design/               Theme, typography, and shared components
  Edit/                 Structured editor and safe re-import
  Health/               Explicit Apple Health export
  Import/               Import coordinator and recovery surfaces
  Library/              Recipes, Discover, Watch, and Inbox workspace tabs
  Notifications/        Import completion notifications
  Nutrition/            Nutrition detail
  RecipeDetail/         Editorial recipe presentation
LadleShare/             iOS Share Extension
Packages/LadleCore/     Domain models, querying, cooking, and shared queue
LadleTests/             App and persistence tests
Config/                 Plists and entitlements
Backend/                FastAPI API, Celery worker, PostgreSQL schema
  ladle/api/            HTTP composition, routes, errors, health
  ladle/contracts/      Strict JSON wire DTOs
  ladle/db/             SQLAlchemy models and sessions
  ladle/acquisition/    Supadata and SoScripted adapters
  ladle/extraction/     Claude structured recipe extraction
  alembic/              Versioned PostgreSQL migrations
  docs/                 Backend integration and schema reference
docs/plans/             Product design and implementation plans
docs/verification/      Verification records
project.yml             XcodeGen project definition
```

## Requirements

- Xcode with the iOS 26.5 SDK
- An iPhone simulator; the verified reference device is iPhone 17
- XcodeGen 2.46 or newer when regenerating the project

The generated `Ladle.xcodeproj` is checked in. Regenerate it after adding or
removing source files:

```bash
xcodegen generate
```

## Build and run

Open `Ladle.xcodeproj`, select the `Ladle` scheme and an iPhone simulator, then
Run.

Physical Debug builds that use local Docker must use the guarded device tunnel
instead of `.localhost`. From `Backend/`, run
`./scripts/device_tunnel.sh rotate`, then pass
`.private/DeviceTunnel.xcconfig` to `xcodebuild` with `-xcconfig`. The backend
README documents the complete rotate/start/stop workflow.

For a command-line simulator build:

```bash
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Production-device HealthKit, notification, App Group, and Sign in with Apple
behavior requires the corresponding signing capabilities configured for your
team. The app and extension currently share `group.com.ladle.ios`. Google also
requires the ignored `.private/GoogleAuth.xcconfig`; start from
`Config/GoogleAuth.xcconfig.example`.

For local SSO, set the Apple and Google variables in `Backend/.env`. The local
Compose profile forwards them to the API and mounts
`LADLE_APPLE_PRIVATE_KEY_FILE` read-only at runtime; the key stays outside the
container image and Git. Google App Check prewarming is best-effort so a
transient or simulator-only prewarm failure does not block the OAuth screen;
the Google SDK retries while building the authorization request.

## Run the backend

```bash
cd Backend
docker compose up -d --build
curl --fail http://127.0.0.1:4112/health/ready
```

The iOS Debug configuration expects `http://api.ladle.localhost`. The root
`Caddyfile` routes that hostname to host port 4112. If Caddy is not running,
point `Config/Debug.xcconfig` directly at `http://127.0.0.1:4112`.

See the
[backend integration reference](Backend/docs/integration-reference.md) for
the complete path map, HTTP API and payload examples, provider configuration,
iOS connection steps, PostgreSQL relationships, table definitions, migration
commands, and troubleshooting.

The OVH server has a concise
[VPS deployment and recovery runbook](Backend/docs/deployment/vps.md) covering
the five-container runtime, shared Caddy routing, Apple/Google OAuth, backups,
and Git-revision rollback.

## Test

Run the domain package:

```bash
swift test --package-path Packages/LadleCore
```

Run the app and Share Extension unit tests. Tests are disabled on the default
`Ladle` scheme so ordinary builds stay fast — use the `LadleAllTests` scheme:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Add `-only-testing:LadleTests` for just the unit suite: 404 tests in under four
seconds, against a few minutes for the 20 UI tests, each of which pays for
its own app launch.

Run the backend suite from `Backend/`:

```bash
uv run pytest
```

That is the same selection CI gates on: every tier except `live_provider` (needs
a real provider key) and `chaos` (kills real workers, so it needs a host to
itself). Both are configured in `addopts`, along with `-n auto`, which splits the
run across cores — each worker starts its own throwaway PostgreSQL through
testcontainers, so a Docker daemon is the only prerequisite. Override on the
command line: `-m chaos` or `-m live_provider` to select a held-back tier, `-n0`
to run serially when a failure is easier to read that way. CI can skip the whole
suite through the `RUN_BACKEND_TESTS` flag in
`.github/workflows/backend-ci.yml`.

## Deterministic demo and test imports

The explicitly injected `DemoImportService` accepts HTTP(S) links from TikTok,
Instagram, YouTube, and `youtu.be`. Its deterministic path tokens make
recovery states reproducible:

- Ordinary supported links return a ready recipe.
- `slow` introduces the parsing delay used by the background-card flow.
- `review` or `needs-review` returns the exceptional check-details state.
- `private` or `deleted` returns the private/deleted failure.
- `network` or `offline` returns the network failure.
- `parser` or `failed` returns the parser failure.
- Pasted recipe details recover to a ready recipe.
- Correction notes containing `simulate failure` exercise safe re-import
  failure; other correction notes produce a ready candidate.

These tokens apply only to the demo service. The normal app composition uses
the remote backend; local Compose selects deterministic fake providers through
server configuration.

UI tests can also select exactly one whole-app state with
`-demo-scenario <name>`. Supported names are `empty`, `offline-content`,
`offline-empty`, `store-failure`, `discover-empty`,
`discover-rate-limited`, `import-quota`, `import-rate-limited`,
`authentication-expired`, and `large-library`. These switches are ignored
outside an explicit `-ui-testing` launch. Missing, unknown, duplicated, or
conflicting scenario arguments fall back to the standard demo, so fixtures
cannot construct contradictory product states.

## Product and verification notes

- Conservative inferred ingredient amounts and nutrition remain visibly
  estimated wherever the source is uncertain. Missing nutrition alone never
  turns an otherwise cookable recipe into an Inbox review task.
- Apple Health authorization is deferred until the user reviews values and
  confirms an export.
- Notification denial never changes a successfully persisted recipe or import
  state.
- Safe re-import preserves the current recipe until a ready replacement has
  been persisted.
- Share Extension envelopes are atomic, idempotent, and retained for retry
  when reconciliation cannot persist them.
- Share Extension imports accept URL attachments, plain text, and an extension
  item's attributed text. The backend canonicalizes the direct and share-link
  forms emitted by Instagram, TikTok, and YouTube.

See [the Ladle v1 verification record](docs/verification/2026-07-23-ladle-v1.md)
for the command results and screen-by-screen visual review.

See the
[production backend verification record](docs/verification/2026-07-23-ladle-backend.md)
for API, infrastructure, cache, sync, and acceptance-test evidence.
