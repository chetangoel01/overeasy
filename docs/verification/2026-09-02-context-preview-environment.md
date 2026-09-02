# Context-menu previews see the app's environment

**Date:** September 2, 2026 · **Branch:** `fix/context-preview-environment` · **Issue:** #61

## Purpose

Long-pressing a recipe — a Recipes row or card, a Discover card, the Watch
feed — opens the native context menu with a preview of the recipe. On the
phone the preview drew the placeholder pan while the row beneath it showed
the thumbnail. The preview is the reason to long-press; without artwork it
is a title card.

## What was wrong

UIKit hosts a context-menu preview in a view hierarchy of its own, and
custom SwiftUI environment values do not follow it there. `RecipeArtworkView`
reads the download cache from `@Environment(\.remoteImageCache)`; inside a
preview it was `nil`, so the load task returned to `.placeholder` before it
ever looked at the in-memory cache that already held the row's decoded
image. `@Environment(\.ladleAccent)` was lost the same way: the preview's
creator label rendered in the tomato default whatever accent the cook had
chosen.

Demo and UI-test builds never showed either symptom. Fixture artwork is a
bundled asset drawn by name, which needs no cache, and the default accent is
tomato. The accent is what made the fault visible without a backend: with
the accent set to Sage in a demo build, the preview label came out tomato
(the "before" capture) while everything around it was sage.

## Change

- `ladleContextMenu(menuItems:preview:)` in `Ladle/Library/RecipeContextMenu.swift`
  reads `remoteImageCache` and `ladleAccent` where the menu is attached and
  applies both to the preview. The three preview sites — `recipeContextMenu`
  (Recipes and Watch's saved recipes), `discoverContextMenu` in
  `DiscoverView.swift`, and the Discover branch in `WatchView.swift` — go
  through it, so the next preview cannot forget to. These are the only two
  custom environment keys in the app.
- `RecipeArtworkView`'s load task checks `RecipeArtworkMemoryCache` before it
  needs the download cache at all. A preview of a row already on screen finds
  its decoded image there even if a host passes nothing down.

Nothing changes for rows, cards or the detail screen: they read the same
environment they always did.

## Verification

Captures in `docs/verification/captures/2026-09-02-context-preview-environment/`,
all on the "Overeast UI validation" simulator (iOS 26.5):

- `before-preview-sage-accent.png` — demo build (`-ui-testing
  -onboarding-complete`), accent Sage, long-press on a Recipes card: the
  preview's creator label is tomato. This is the environment loss.
- `after-preview-sage-accent.png` — same build with the fix, same steps: the
  label is sage.
- `after-discover-remote-thumbnail.png` — Debug build against the local
  stack (`api.ladle.localhost`), Discover card with a remote image: the
  preview shows the thumbnail. This is the symptom from the phone, fixed.

No automated test can exercise UIKit's preview hosting, so the captures are
the evidence. `LadleTests` (417 tests) run green on the fix. The long-press
UI test (`DiscoverInteractionUITests/testDiscoverRecipeSupportsTapAndLongPress`)
fails on `main` with and without the fix, for a reason of its own (#65); the
six other tests in that file pass. The phone gets the Release build against
the VPS once the PR merges.
