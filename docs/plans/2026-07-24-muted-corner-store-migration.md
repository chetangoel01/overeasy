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
- A needs-review re-import keeps its candidate isolated until the comparison
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
