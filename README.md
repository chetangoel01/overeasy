# Ladle

Ladle is a native iPhone recipe workspace for turning scattered social-video
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

This repository is a polished native v1 prototype. `DemoImportService`
provides deterministic import outcomes and recipe fixtures; it does not fetch
or parse live social-video content. Account actions model local product states
and are not connected to a production authentication backend.

The Share Extension queue, SwiftData persistence, notification scheduling,
and HealthKit export paths use native platform APIs.

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
LadleUITests/           End-to-end and visual verification flows
Config/                 Plists and entitlements
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

## Test

Run the domain package:

```bash
swift test --package-path Packages/LadleCore
```

Run the app, Share Extension, and UI suites:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

The accessibility UI flows launch with
`UICTContentSizeCategoryAccessibilityL` and verify that the library, recipe,
cooking, and timer actions remain labeled and hittable.

## Test launch flags

The UI suite uses these deterministic launch arguments:

- `-ui-testing` uses an in-memory store and disables system permission prompts.
- `-onboarding-complete` opens directly to the recipe library.
- `-reset-onboarding` presents the welcome experience.
- `-reset-library-preferences` restores grid display.

## Deterministic demo imports

The importer accepts HTTP(S) links from TikTok, Instagram, YouTube, and
`youtu.be`. Its deterministic path tokens make recovery states reproducible:

- Ordinary supported links return a ready recipe.
- `slow` introduces the parsing delay used by the background-card flow.
- `review` or `needs-review` returns a recipe that needs review.
- `private` or `deleted` returns the private/deleted failure.
- `network` or `offline` returns the network failure.
- `parser` or `failed` returns the parser failure.
- Pasted recipe details recover to a ready recipe.
- Correction notes containing `simulate failure` exercise safe re-import
  failure; other correction notes produce a ready candidate.

No production extraction or authentication endpoints are configured. Live
social parsing, media retrieval, and account services remain deferred backend
integrations.

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
