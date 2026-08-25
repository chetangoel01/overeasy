# Settings, Discover, and library layout

Date: August 25, 2026

## Purpose

Give cooks a small amount of visual personalization, keep recipe processing
non-blocking, stop saved sources from returning to Discover, and make the recipe
archive easier to scan in either grid or list form.

## User-visible behavior

- The former Account sheet is titled Settings and includes five persistent
  accent choices: Tomato, Orange, Sage, Blue, and Purple.
- The chosen accent updates primary actions, active navigation, favorites, and
  attention indicators. Destructive actions remain system red, and Focus Mode
  keeps its fixed high-contrast action color.
- A processing recipe sheet can be closed with Close or Keep browsing. The
  app-owned import coordinator continues the durable job after dismissal.
- Discover omits sources already saved by the current account. Directly saving
  a row removes it from the visible feed when the server confirms the save.
- Recipe view is an explicit Grid/List menu. The choice persists locally. Grid
  artwork is square, columns adapt to available width, and large Dynamic Type
  uses one column.

## Important decisions

- Accent customization uses a curated palette instead of an unrestricted color
  picker so action contrast and semantic color roles remain predictable.
- Saved-source exclusion happens on the server before the Discover limit is
  applied. The app also filters saved results for compatibility with an older
  server response.
- Dismissing processing does not introduce a second task system. The existing
  coordinator already outlives the sheet and owns persistence, polling, and
  completion notification.
- The existing list implementation and persisted display preference were
  retained. Only the control clarity and grid geometry changed.

## Affected components

- `Ladle/Design/LadleTheme.swift`
- `Ladle/App/LadleApp.swift`
- `Ladle/Account/AccountSheet.swift`
- `Ladle/RecipeDetail/RecipeOptionsSheet.swift`
- `Ladle/Library/AllRecipesView.swift`
- `Ladle/Library/RecipeGridCard.swift`
- `Ladle/Library/DiscoverView.swift`
- `Backend/ladle/recipes/repository.py`

## Verification

- Accent preference tests cover the stable stored values and fallback.
- Discover view-model tests cover filtering server-marked saves and removing a
  row after direct save.
- The Docker-backed Discover API integration test proves that a saved source is
  excluded on refresh.
- Simulator UI coverage selects Blue in Settings, switches from Grid to List,
  verifies a list row, and captures both layouts.
- Simulator UI coverage starts a deliberately slow import, taps Keep browsing,
  and verifies that the recipe library is immediately usable.
- Visual inspection on iPhone 17 Pro confirmed readable settings hierarchy,
  equal swatch targets, square grid artwork, and unclipped list content.
