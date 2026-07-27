# Muted Corner Store Migration

## Purpose

Move the existing native Ladle implementation to the approved complete screen
atlas while preserving tested import, persistence, editing, cooking, Health,
notification, accessibility, and Share Extension behavior.

## Approved behavior

- Home and All Recipes replace the single undifferentiated library.
- Search appears on demand.
- Import Inbox centralizes parsing, review, and failed jobs.
- Watch provides image-first vertical recipe rediscovery with source fallback.
- Macro filtering supports minimum protein and maximum calories,
  carbohydrates, and fat.
- Sorting supports recently saved, recipe name, fastest, highest protein, and
  lowest calories.
- Recipe detail switches between Ingredients and Method.
- Secondary recipe actions move to a sheet.
- Focus Mode uses the plum cooking surface and explicit timer states.
- Home can distinguish recipes that have and have not been cooked.

## Implementation checkpoints

1. Document the approved system and align product language.
2. Add domain and design-token regression tests.
3. Replace color, type, shape, and shared state components.
4. Build Home, All Recipes, Search, Import Inbox, and Watch.
5. Migrate recipe, editor, import, re-import, nutrition, and Health surfaces.
6. Migrate Full Recipe, Focus Mode, and timer states.
7. Run LadleCore tests, focused UI tests, the full app test target, full app and
   Share Extension builds, simulator visual review, and `git diff --check`.

## Decisions

- The HTML atlas communicates hierarchy and state, not production point sizes.
- Native controls replace simulated HTML system dialogs and glyphs.
- SF Rounded is limited to short display roles. Long cooking instructions use
  SF Pro for distance legibility.
- Dusty brick is darkened to `#AD503D` for accessible text contrast.
- Existing behavior remains authoritative where the visual artifact omits an
  edge case.
- Third-party playback falls back to stored imagery and the original source URL
  because recipe records do not contain direct playable media URLs.

## Verification record

- Domain checkpoint: 28 LadleCore tests pass. Coverage includes ingredient
  search, composable per-serving macro filters, highest-protein sorting, and
  optional cooking history.
- Design-foundation checkpoint: the focused DesignTokenTests suite passes.
  The app and Share Extension compile with the approved accessible palette,
  rounded display typography, shared icon controls, and shared state layout.

### Checkpoint 4: Library destinations

Purpose:

- Turn the former single archive into distinct places for rediscovery,
  retrieval, import recovery, and source-video recall.

User-visible behavior:

- Home now leads with Import Inbox and Watch entry points, followed by recipes
  saved this week and useful quick, favorite, and uncooked groups.
- All Recipes owns sorting, list/grid choice, collection scopes, and removable
  time, calorie, protein, carbohydrate, and fat filters.
- Search is a dedicated destination and searches the complete saved library
  without inheriting archive filters.
- Import Inbox shows parsing, review, and failed jobs together; failed jobs
  retain the existing retry, correction, paste, and manual recovery flow.
- Watch uses the plum surface, image-first vertically snapping cards,
  Overview/Ingredients/Method panels, source fallback, favorite/share actions,
  recipe detail, and cooking entry points.

Important decisions:

- Search query state is local to Search so opening a result does not silently
  change the All Recipes archive.
- Needs-review import jobs retain the recipe identifier required to reopen the
  saved recipe from Import Inbox after the original import sheet is gone.
- A needs-review re-import keeps its candidate isolated until the review
  flow in checkpoint 5. Inbox opens the still-safe current recipe with an
  explicit pending-review status instead of presenting an inert candidate.
- Watch includes recipes imported from TikTok, Instagram, and YouTube; manual
  recipes remain in Home, All Recipes, and Search.
- Archive and Watch nutrition facts use the same per-serving scaling as macro
  filters, so visible values and filtering thresholds remain consistent.
- Stored imagery is the Watch preview. The play action opens the durable
  original URL because recipe records do not store a playable media stream.
- Existing failed-import recovery remains a sheet so the original coordinator
  and pending recipe navigation behavior stay intact.

Affected components:

- `LibraryView`, `LibraryViewModel`, `FilterSheet`, and `PendingImportCard`
- `LibraryChrome`, `LibraryHomeView`, `AllRecipesView`, `LibrarySearchView`,
  `ImportInboxView`, and `WatchView`
- `LibraryViewModelTests`

Verification:

- Red-green coverage was added for Home groups, composable collection/macro
  filters, independent filter removal, dedicated search isolation, import
  attention counts, and Watch source selection.
- 29 LadleCore tests and 77 app unit tests pass with zero failures.
- The Ladle app and Share Extension build for the iPhone 17 simulator.
- Seeded Home was visually inspected on iPhone 17 for hierarchy, spacing,
  imagery, clipping, and device-safe layout.
- The outgoing UI automation suite is intentionally deferred during this
  sweeping interface migration at the user's direction. It still contains
  assertions for replaced screens and will be rewritten after the remaining
  atlas surfaces stabilize.

### Checkpoint 5: Recipe, recovery, nutrition, and Health

Purpose:

- Keep structured cooking content primary while making editing, recovery,
  replacement, nutrition, and Health actions easy to reach without crowding
  the recipe.

User-visible behavior:

- Recipe detail switches between Ingredients and Method in place, keeps the
  active content above Start Cooking, and moves edit, re-import, nutrition,
  and source actions into the ellipsis options sheet.
- The existing six-part editor remains the approved Basics, Media, Timing,
  Ingredients, Method, and Nutrition flow, including ordered item controls,
  validation, and unsaved-draft protection.
- A failed link import now exposes retry, correction notes, pasted details,
  and manual creation immediately; the same recovery actions are reused from
  Import Inbox.
- Ready and needs-review re-imports show the still-safe current recipe, the
  complete candidate ingredients and method, and explicit accept/keep actions.
- Recipe facts, the Nutrition screen, archive rows, and Watch all use one
  per-serving nutrition presentation. Apple Health continues to scale from
  the stored serving basis to the amount the user confirms.

Important decisions:

- Recipe option actions wait for the options sheet to dismiss before
  presenting another sheet or opening the source URL.
- Re-import candidates remain isolated from the saved library until accepted
  but are stored with the import job so review can resume after relaunch.
  Closing a pending decision explicitly keeps the current recipe.
- Acceptance marks the candidate ready and atomically swaps the recipe and
  import-job records in one SwiftData save.
- Import coordinator state is scoped to its job and re-import recipe so Add,
  Retry, and Re-import cannot consume or overwrite one another’s work.
- Invalid serving bases never relabel totals as per-serving values; nutrition
  and Health export remain unavailable until the basis is valid.
- Health authorization is still requested only after the user reviews the
  scaled payload and confirms export.
- Shared recipe/source/ingredient presentation helpers replace duplicate
  formatting across library, detail, Watch, Nutrition, and cooking surfaces.

Affected components:

- `RecipeDetailView`, `RecipeMetadataBand`, `RecipeOptionsSheet`
- `AddRecipeSheet`, `FailedImportSheet`, `ImportRecoveryActions`
- `ReimportSheet`, `ImportCoordinator`, `ReimportSafetyTests`
- `NutritionView`, `RecipePresentation`, and shared recipe row/cooking users

Verification:

- Red-green coverage proves that ready and reviewed candidates leave the
  current recipe untouched until acceptance, survive coordinator reset, can be
  discarded, and cannot be overwritten by another import.
- SwiftData coverage verifies candidate round-tripping and the atomic recipe
  replacement path; presentation coverage excludes invalid serving bases.
- 31 LadleCore tests and 85 app unit tests pass with zero failures, including
  focused editor, import, re-import, library-presentation, and Health export
  coverage.
- The Ladle app and Share Extension build for the iPhone 17 simulator.
- `git diff --check` passes.
- The outgoing UI automation suite remains deferred until the remaining
  cooking surfaces stabilize, as requested.

### Checkpoint 6: Full Recipe, Focus Mode, and timers

Purpose:

- Keep the complete cooking workspace useful for preparation while giving one
  active step and its timer enough contrast for hands-busy cooking.

User-visible behavior:

- Full Recipe keeps the ingredient checklist, method completion, timer
  controls, explicit screen-awake toggle, and shared cooking progress on the
  paper surface.
- The current step is selectable from the compact progress control, and Focus
  Mode remains one tap away without crowding the recipe.
- Focus Mode now owns the plum surface, with large distance-readable
  instructions, a celery progress treatment, relevant ingredient names, and
  explicit previous/next controls in addition to swipe navigation.
- Idle, running, paused, and finished timers retain the same countdown,
  notification, pause, reset, and accessibility behavior. A finished timer
  changes the step state to an unmistakable completion message and Continue
  cooking action.

Important decisions:

- Starting a timer remains the only action that may request notification
  permission; entering cooking or Focus Mode never prompts.
- Pausing or resetting while authorization is pending invalidates that
  notification generation so a stale alert cannot be installed afterward.
- Focus Mode keeps all timers attached to a step rather than assuming the
  single timer shown in the atlas is a domain limit.
- The screen-awake setting remains opt-in and restores the previous system
  setting when cooking ends.
- Step and ingredient completion, current position, and timers remain shared
  across Full Recipe and Focus Mode.
- Accessibility keeps a visible previous-step control even though the atlas
  relies primarily on swiping.

Affected components:

- `FullRecipeView`, `FocusModeView`, and `RecipeTimerButton`
- `CookingViewModel` and `CookingViewModelTests`

Verification:

- Focused cooking tests cover shared mode state, clamped navigation, relevant
  ingredients, all timer phases, explicit notification scheduling, finished
  timer presentation, and screen-awake restoration.
- 31 LadleCore tests and 86 app unit tests pass with zero failures.
- The Ladle app and Share Extension build for the iPhone 17 simulator.
- The approved cooking atlas states were reviewed at full fidelity against the
  native hierarchy, state labels, controls, contrast, and scaling behavior.
- `git diff --check` passes.
- The outgoing UI automation suite remains deferred for its final atlas-aware
  rewrite, as requested.

### Checkpoint 7: Import continuity and dark appearance

Purpose:

- Keep import recovery useful without turning it into a persistent obstruction,
  and extend the approved visual language to the system dark appearance.

User-visible behavior:

- Home shows Import Inbox only for actionable work, while the destination
  supports swipe deletion and clears itself when the work is resolved.
- Review completion clears the recipe and inbox state together, and a saved
  re-import decision no longer blocks unrelated imports.
- Native destination navigation restores the standard iOS edge-swipe back
  gesture.
- Share confirmation waits for an explicit Done action, Welcome avoids
  unnecessary scrolling, and all shared surfaces adapt to a warm dark palette.

Important decisions:

- System navigation and list gestures are used instead of custom substitutes.
- SF Rounded remains the display face and SF Pro remains the body face.
- Dark appearance uses semantic asset variants and a fixed on-accent
  foreground; feature views do not branch on appearance.
- The Mac mini profile copies provider thumbnails into private MinIO storage,
  backfills legacy remote references, and serves only short-lived signed reads
  through its ngrok listener.
- Recipe extraction can bridge an uncertain method from general cooking
  knowledge only when it marks the result for review and avoids invented exact
  facts.

Verification:

- See
  `Docs/verification/2026-07-27-import-inbox-and-dark-mode.md` for regression,
  build, visual, deployment, and physical-device evidence.
