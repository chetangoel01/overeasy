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
