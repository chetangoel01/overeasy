# Ladle Native iOS Design

## Product intent

Ladle is a native, iPhone-first recipe library that turns recipe links from TikTok, Instagram, and YouTube into dependable, editable recipes. Its primary promise is that a user can share a link once, return immediately to the source app, and later find a clear recipe ready to cook.

The first implementation is a complete native vertical slice. Every supplied v1 screen will have a functional SwiftUI counterpart, local data will persist, the Share Extension and HealthKit boundaries will be real, and content extraction will sit behind a replaceable service protocol. A deterministic local implementation will make the whole app usable before a production backend is connected.

## Approved constraints

- Product name: Ladle
- Platform: native iPhone app in Swift and SwiftUI
- SDK and minimum deployment target: iOS 26.5
- Language mode: Swift 6 with strict concurrency
- Visual source of truth: `Recipe app design v1 screens.zip`
- Visual direction: warm paper, near-black ink, paprika accent, generous spacing, system controls, and system serif typography for editorial titles
- Default library presentation: imagery-forward grid with an accessible grid/list switch
- Recipe detail presentation: contained editorial treatment
- No paid subscription or post-v1 features

## Targets and code organization

The Xcode project contains three logical products.

### Ladle app

The main SwiftUI application owns onboarding, account state, the recipe library, editing, cooking modes, nutrition, HealthKit export, and recovery flows.

### Ladle Share Extension

The Share Extension:

1. extracts the first supported HTTP or HTTPS URL from the extension context;
2. creates a durable import job in the shared App Group container;
3. attempts to submit the job through a background-capable import client;
4. shows the compact “Added to Ladle” confirmation as soon as the URL is safe;
5. dismisses without waiting for parsing.

An unsupported or malformed share is retained as a recoverable failed job when possible.

### LadleCore

Shared application code is organized as a local Swift package or framework so the app, extension, and tests use the same models and rules. It contains:

- domain models and value types;
- import state transitions;
- recipe validation;
- sorting and filtering;
- serving and nutrition calculations;
- repository and service protocols;
- shared App Group queue support;
- design tokens that are safe to share between targets.

Views remain in the app or extension target rather than the core domain module.

## Data model

### Recipe

A recipe stores:

- stable identifier and timestamps;
- title, description, creator, platform, and original URL;
- zero or more image references;
- preparation, cooking, and total time;
- serving count;
- ordered ingredients;
- ordered method steps;
- detected timers attached to steps;
- nutrition and its serving basis;
- favorite status;
- review state and field-level uncertainties;
- the import job that most recently produced a successful version.

Images are represented as local or remote asset references rather than large blobs in the primary SwiftData record.

### Ingredient

An ingredient stores a display quantity, normalized numeric quantity when available, unit, name, optional preparation note, ordering index, and uncertainty state. The display form preserves human-friendly values such as `1 1/2`.

### Recipe step

A step stores its ordering index, instruction text, related ingredient identifiers, zero or more detected timers, completion state for Full Recipe mode, and field-level uncertainty.

### Nutrition

Nutrition stores calories, protein, carbohydrates, total fat, saturated fat, fiber, sugar, sodium, other named nutrients, serving basis, and an explicit estimated flag. Calculations scale from the stored serving basis to the quantity selected for Health export.

### Import job

An import job stores:

- shared URL and inferred source platform;
- creation and update timestamps;
- visible state: parsing, ready, needs review, or failed;
- retry count and recoverable error;
- optional correction notes or pasted recipe text;
- optional remote job identifier;
- current usable recipe identifier;
- candidate replacement recipe identifier during re-import.

The state machine only allows known transitions. A failed re-import discards its candidate and keeps the current usable recipe unchanged.

### Account state

The app begins with a local guest identity. Guest state tracks whether onboarding has been seen and the number of saved recipes. It warns before the tenth recipe, blocks creation after ten without hiding existing content, and can later be migrated to a signed-in account.

## Persistence and shared data

SwiftData is the main local store. The app and Share Extension use an App Group container so the extension can durably enqueue imports. Queue writes are intentionally small and transactional.

The app reconciles shared queue records into SwiftData on launch, scene activation, and background refresh. A production backend can also notify the app of completed jobs with a push notification. The local demo service advances jobs deterministically so every visible state and recovery path can be exercised offline.

Repository protocols isolate SwiftData from feature views and make domain behavior testable with in-memory implementations.

## Service boundaries

### ImportService

`ImportService` accepts new jobs, fetches remote status, retries failed work, and submits correction notes or pasted text. Its production implementation will speak to a backend API. Its demo implementation returns stable sample recipes and controlled failure/review outcomes.

### AccountService

`AccountService` represents guest, free-account, and Sign in with Apple states. Version one can use a local development implementation while preserving the API needed for server-backed identity and guest migration.

### HealthService

`HealthService` explains the data to be written, requests HealthKit permission only after explicit user action, and writes the selected number of servings. Permission denial is a contained result and never disables other features.

### NotificationService

`NotificationService` requests notification permission in context and schedules or handles “recipe ready” notifications. Notifications are helpful but never required to complete an import.

## Navigation and screen behavior

### First launch

The welcome sheet appears over a softened library background. Sign in with Apple, free-account creation, and guest continuation remain distinct actions. Guest limits are stated before entry.

### Library

The library is the root view. It contains:

- title, counts, and Add button;
- native searchable behavior styled to match the edited screens;
- compact sort and filter controls;
- pending import cards above saved recipes;
- grid by default and an optional list presentation;
- favorites and concise time and estimated-calorie metadata.

Search and filters compose predictably. Active limits remain visible and can be removed individually.

### Add and import recovery

Add opens a compact sheet for pasting a link or creating a manual recipe, plus the reminder that sharing is faster. Duplicate links lead to the existing recipe with an option to create another copy.

Failed imports open the supplied recovery sheet: retry, correction notes, paste details, or manual creation. Private, deleted, and unsupported sources retain the link and any recoverable data.

### Recipe detail

The contained image leads into title, attribution, source, stats, and the primary Start Cooking action. Ingredients and method follow. Edit, re-import, detailed nutrition, original video, and favorite are secondary actions.

Uncertain fields are visibly marked without making the entire page look broken. Nutrition consistently uses `≈` and an estimated explanation.

### Editing and re-import

Editing uses structured sections for basics, media, timing, servings, ingredients, steps, and nutrition. Validation is inline and preserves drafts.

Re-import creates a candidate version and accepts correction notes. The existing recipe remains visible and usable until the candidate succeeds. The app never overwrites a working recipe after a failed re-import.

### Cooking modes

Full Recipe mode provides ingredients, method, checkable items, large text, tappable timers, a keep-awake toggle, and entry to Focus Mode.

Focus Mode shows one large step, progress, only the relevant ingredients, optional timers, and previous/next controls. Swipe and tap navigation share the same progress model. Moving between modes preserves the current step and completed items.

Keep-awake behavior is active only while explicitly enabled and a cooking view is onscreen.

### Nutrition and Apple Health

The nutrition sheet emphasizes calories and macros, then lists the remaining nutrients and serving basis. Estimated language is always present.

Health export is an explicit confirmation flow. It shows the selected serving quantity, scaled values, what HealthKit will receive, and the permission implication before writing anything.

## Error handling

User-facing errors are domain-specific and recoverable:

- duplicate URL: open existing recipe or import another copy;
- invalid or unsupported URL: retain a manual-entry path;
- private or deleted content: preserve a draft and original link;
- missing quantities or uncertain transcription: mark affected fields and set needs-review;
- network interruption: keep the queued import and retry safely;
- parser failure: expose the four recovery actions;
- re-import failure: retain the current recipe and report the failed candidate;
- HealthKit denial: report that nothing was written and leave the app fully usable;
- guest limit: offer free-account creation without hiding or disabling saved recipes.

No error path silently discards a link, a usable recipe, or user edits.

## Accessibility

- Interactive targets are at least 44 points.
- Dynamic Type is supported throughout, including cooking modes.
- Color is never the only indication of import or uncertainty state.
- VoiceOver labels include import status, estimated nutrition, favorite state, timer duration, and cooking progress.
- Reduce Motion disables decorative progress animation while preserving state.
- Focus Mode remains legible at arm’s length and in landscape where practical.

## Testing strategy

Development follows red-green-refactor.

### Domain unit tests

- allowed and rejected import state transitions;
- failed re-import preserving the usable recipe;
- guest warning and ten-recipe enforcement;
- duplicate-link decisions;
- combined search, sort, and filters;
- recipe validation and uncertainty propagation;
- serving-scaled nutrition;
- cooking progress shared across both modes;
- timer extraction value handling.

### Persistence and service tests

- SwiftData repository round trips using an in-memory store;
- App Group queue encoding, deduplication, and reconciliation;
- demo import success, needs-review, and failure scenarios;
- Health export payload construction without requiring HealthKit in unit tests.

### UI and integration tests

- guest onboarding to populated library;
- adding a link through the app;
- pending job progressing to ready;
- failed import recovery;
- editing without data loss;
- re-import failure safety;
- switching cooking modes without losing position;
- explicit Health export confirmation.

### Build and visual verification

Both the application and Share Extension must compile for an iOS 26.5 simulator. Tests run from a clean build. Key screens are captured at the supplied 402-by-874 reference size and compared manually for hierarchy, spacing, typography, and state coverage.

## Deferred production dependencies

The native app will define but not invent credentials or undocumented behavior for:

- social-video extraction;
- nutrition estimation;
- server accounts and guest migration;
- remote push notification delivery.

Those capabilities plug into the service boundaries above. The local implementation keeps the v1 app demonstrable and testable until backend endpoints and credentials exist.

## Explicit non-goals

Version one does not include shopping lists, pantry management, meal planning, grocery delivery, discovery feeds, creator following, comments, paid subscriptions, Android, or web.
