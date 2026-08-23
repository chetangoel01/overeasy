# Porcelain library redesign

## Purpose

Replace the warm themed shell and instruction-heavy Home/All hierarchy with a
cool, direct workspace that behaves like a familiar iPhone app.

## User-visible behavior

- Recipes, Watch, and Inbox are persistent native tabs.
- Recipes opens by default with a large title and always-visible search.
- Sort, filter, and grid/list controls are compact and secondary to the archive.
- Generated recipe collections live below the archive instead of inside a
  separate Home destination.
- Inbox shows a badge only for failed or review-required imports.
- Completing review returns to Inbox when work remains and Recipes otherwise.
- Watch uses straightforward scrolling media cards with direct recipe and
  cooking actions.
- Welcome, cooking, import states, and the Share Extension use the same cool
  porcelain, graphite, and signal-red system.

## Decisions

- Removed the custom top bar, Home/All segmented picker, Home feed, and separate
  search destination. Their responsibilities now belong to native navigation,
  tabs, and the Recipes screen.
- Kept legacy color-token names to avoid a broad mechanical migration; their
  current semantic roles are documented in `DESIGN.md`.
- Reserved signal red for actions, selected navigation, favorites, progress,
  and attention. Food photography remains the dominant color in the library.
- Used standard-width SF Pro with bold or semibold hierarchy instead of expanded
  display typography.

## Affected components

- `LadleTheme`, asset-catalog colors, and `LadleTypography`
- `LibraryView`, `AllRecipesView`, `WatchView`, and `ImportInboxView`
- Welcome/onboarding and Focus Mode color usage
- Share Extension confirmation styling and copy
- Navigation, palette, smoke, and share rendering tests

## Verification

- Red-green coverage added for the porcelain/graphite palette and tab-root
  navigation behavior.
- Targeted app tests: 33 passed on the `Ladle-Verify` iOS simulator.
- Full app suite: 161 passed, 1 skipped, 0 failed on `Ladle-Verify`.
- LadleCore: 43 passed, 0 failed.
- The full simulator app build passed with `LadleShare.appex` embedded.
- Simulator inspection at 402 × 874 points covered Recipes in light and dark,
  Watch, Inbox, recipe detail, Full Recipe, Focus Mode, and welcome.
- `git diff --check` passed before the checkpoint commit.
