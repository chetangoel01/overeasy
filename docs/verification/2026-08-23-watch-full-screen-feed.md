# Watch full-screen feed

Date: August 23, 2026

## Purpose

Restore Watch as a focused, video-first rediscovery surface. A saved social
recipe should own the viewport, respond like a native vertical feed, and avoid
showing the same deterministic recent-first order every session.

## User-visible behavior

- Each saved TikTok, Instagram, or YouTube recipe occupies exactly one Watch
  viewport with full-bleed artwork.
- Vertical dragging tracks the finger through the native scroll view and
  settles on one recipe at a time with paging momentum.
- The video play action remains centered over the source artwork. Creator,
  platform, metadata, favorite, share, recipe, and cooking actions remain
  directly available without reproducing the full recipe detail screen.
- Watch uses its own compact overlaid title and Account action so the standard
  large navigation bar does not reduce the feed viewport.
- The eligible recipes are shuffled once on the first library load. Ordinary
  reloads preserve that order, which prevents favorites and sync refreshes from
  moving the currently visible recipe.
- Manual recipes remain excluded. New video recipes join the end of the stable
  session order after being shuffled with any other new additions.
- Recipe and cooking actions stack vertically for a stable full-width target
  at every Dynamic Type size, while icon controls preserve 44-point targets.

## Important decisions

- Native `ScrollView` paging provides continuous gesture tracking, momentum,
  interruption, and system accessibility behavior without a custom drag
  recognizer.
- The feed displays stored artwork and opens the existing durable platform
  embed player on demand. Keeping web players out of every scroll cell avoids
  gesture conflicts and unnecessary simultaneous web views.
- Randomness lives in `LibraryViewModel`, where the ID order can remain stable
  across view redraws and repository reloads. The shuffler is injectable only
  to make the ordering contract deterministic in its focused test.

## Affected components

- `Ladle/Library/WatchView.swift`
- `Ladle/Library/LibraryView.swift`
- `Ladle/Library/LibraryViewModel.swift`
- `LadleTests/LibraryViewModelTests.swift`
- `LadleUITests/DiscoverInteractionUITests.swift`
- `DESIGN.md` and `README.md`

## Verification

- The shuffle regression was written first and failed because the view model
  did not yet accept or retain a shuffled order.
- All 26 `LibraryViewModelTests` pass, including the new shuffle and stable
  reload regression.
- The focused Watch UI test verifies that Play, Account, and Start Cooking are
  reachable, one upward swipe reveals a different recipe, and the prior recipe
  leaves the viewport.
- The UI-test screenshot was inspected at the native 402 by 874-point viewport:
  the artwork is full bleed, all overlay text and controls are visible, and the
  bottom actions clear the floating tab bar.
- The Ladle app builds for the `Ladle-Verify` iOS 26.5 simulator, and the built
  app bundle contains the embedded `LadleShare.appex` Share Extension.
