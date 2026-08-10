# Ladle (ships as **Overeasy**)

Ladle — shipping under the product name **Overeasy** — is a native iPhone recipe workspace for turning scattered social-video
links into structured recipes that are easier to save, review, and cook.

The app follows a warm editorial visual system built around cream paper,
paprika accents, serif headlines, food photography, and intentionally quiet
controls. It is implemented in SwiftUI with a SwiftData persistence layer and
a separate `LadleCore` domain package.

## What is included

- Guest onboarding with an explicit ten-recipe limit
- Link, manual-entry, and iOS Share Extension import entry points
- Durable Share Extension queue reconciliation through an App Group
- Parsing, needs-review, ready, duplicate, and recoverable failure states
- Search, sorting, filters, grid/list display, and favorites
- Structured recipe detail, editing, and safe re-import
- Clearly labeled estimated nutrition and serving-basis details
- Explicit, review-first Apple Health nutrition export
- Full Recipe and Focus cooking modes with shared completion state
- Detected timers, local timer notifications, and opt-in keep-awake behavior
- Ready-only import completion notifications requested in context
- Dynamic Type layouts, Reduce Motion behavior, semantic controls, and
  44-point primary hit regions

## Current product boundary

The native app is connected to the FastAPI backend through real guest
authentication, Sign in with Apple, remote import polling, and offline-first
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
  Library/              Search, filters, cards, grid/list library
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

For a command-line simulator build:

```bash
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Production-device HealthKit, notification, and App Group behavior requires
the corresponding signing capabilities configured for your team. The app and
extension currently share `group.com.ladle.ios`.

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

Run the app and Share Extension unit tests:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

## Deterministic demo and test imports

The explicitly injected `DemoImportService` accepts HTTP(S) links from TikTok,
Instagram, YouTube, and `youtu.be`. Its deterministic path tokens make
recovery states reproducible:

- Ordinary supported links return a ready recipe.
- `slow` introduces the parsing delay used by the background-card flow.
- `review` or `needs-review` returns a recipe that needs review.
- `private` or `deleted` returns the private/deleted failure.
- `network` or `offline` returns the network failure.
- `parser` or `failed` returns the parser failure.
- Pasted recipe details recover to a ready recipe.
- Correction notes containing `simulate failure` exercise safe re-import
  failure; other correction notes produce a ready candidate.

These tokens apply only to the demo service. The normal app composition uses
the remote backend; local Compose selects deterministic fake providers through
server configuration.

## Product and verification notes

- Nutrition remains visibly estimated wherever the source is uncertain.
- Apple Health authorization is deferred until the user reviews values and
  confirms an export.
- Notification denial never changes a successfully persisted recipe or import
  state.
- Safe re-import preserves the current recipe until a ready replacement has
  been persisted.
- Share Extension envelopes are atomic, idempotent, and retained for retry
  when reconciliation cannot persist them.

See [the Ladle v1 verification record](docs/verification/2026-07-23-ladle-v1.md)
for the command results and screen-by-screen visual review.

See the
[production backend verification record](docs/verification/2026-07-23-ladle-backend.md)
for API, infrastructure, cache, sync, and acceptance-test evidence.
