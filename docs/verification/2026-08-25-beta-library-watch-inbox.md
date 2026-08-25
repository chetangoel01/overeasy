# Beta library, Watch, Inbox, and nutrition release

Date: August 25, 2026

## Purpose

Ship the outstanding beta feedback as one coherent TestFlight update: make
processing safely dismissible, distinguish closing from cancellation, keep
saved discoveries gone, repair the compact recipe grid, offer alternate library
views, clarify the four-tab workspace, and make useful nutrition visible
without overwhelming the recipe.

The release build number is `20260825.1`.

Ingredient sticker artwork is intentionally outside this release. The visual
direction remains parked in `design/board/ingredient-icon-directions.html` for
the next design pass.

## User-visible behavior

- A cold launch starts on Recipes. Ordinary background/resume preserves the
  current tab and navigation stack.
- Discover uses the food-specific fork-and-knife tab symbol. Saving a source
  suppresses it for that account on later refreshes and relaunches, even if the
  owned recipe is later deleted.
- Watch opens on Discover the first time and offers My Recipes and Discover in
  one segmented full-screen feed. The selected segment survives tab switches.
  Saving a Discover video does not stop playback or remove the current item;
  the suppression becomes visible after Watch is left and reopened.
- Recipes remains recently saved by default. Grid uses two capped, aligned
  compact columns with reserved title/fact space, List uses a denser 72-point
  thumbnail row, and Gallery is a static three-column image-first view. The
  selected view persists locally.
- The processing sheet expands to the large presentation, can be swiped down
  or closed with the top-left X without affecting work, and shows a separate
  destructive Cancel Import action only while active. Cancellation requires
  confirmation, terminates the remote job, releases its reservation, deletes
  the local job, and removes the Inbox row.
- Tapping an active Inbox row reopens the same processing state. Check-details
  and failed rows remain actionable; successful ready jobs do not linger.
  Active rows use a platform-recipe fallback until a real video title or
  caption is available, then prefer the extracted title and creator.
- A ready notification carries the recipe identifier. Tapping it selects
  Recipes and opens that recipe directly.
- Grid and List show compact per-serving protein and calories. Exact nutrition
  is not marked approximate. Recipe detail shows a tappable Calories, Protein,
  Carbs, and Fat strip; the existing full Nutrition sheet contains saturated
  fat, fiber, sugar, sodium, and any additional micronutrients.

## Import confidence decisions

- Missing or unavailable nutrition stays as an inline uncertainty and does not
  create an Inbox review task.
- One missing quantity in a short otherwise usable recipe does not force
  review. Review remains for effectively unmeasured recipes and reconstructed
  methods, while field-level caveats remain visible beside their data.
- The server keeps cancelled jobs as terminal audit state, but cancellation is
  a `204` endpoint rather than a new client-visible status.

## Important implementation decisions

- Discover suppression uses account-owned source history on the server instead
  of an install-only preference, so standalone Discover and Watch agree across
  devices and after recipe deletion.
- Watch reuses the existing Discover service and keeps a session snapshot after
  save. Refreshing that snapshot applies the server suppression without
  mutating the currently playing page.
- The same cached `RecipeArtworkView` renders Discover rows and their native
  context previews, preventing a mismatched preview image.
- The existing four-tab architecture, import coordinator, nutrition model, and
  full nutrient sheet are extended directly; no parallel navigation or
  nutrition system was added.

## Affected components

- `Ladle/Library`: root tabs, Recipes presentation, Discover, Watch, Inbox, and
  recipe cards
- `Ladle/Import`: coordinator, remote service, and processing sheet
- `Ladle/Notifications`: notification routing
- `Ladle/RecipeDetail` and `Ladle/Nutrition`: nutrition summaries and details
- `Backend/ladle/imports`, recipe discovery, extraction review, and nutrition
  enrichment
- Alembic migration `0014`

## Verification

- Focused iOS tests cover Gallery preference persistence, session-stable Watch
  saves, confirmed cancellation, navigation defaults, notifications, and
  existing import durability.
- Backend unit coverage protects the relaxed short-recipe quantity rule and
  nonblocking nutrition failures. API coverage protects cancellation and
  permanent Discover suppression after deletion.
- `swift test --package-path Packages/LadleCore`: 45 passed.
- Backend `.venv/bin/pytest -q`: 692 passed, 5 skipped. The only warning is a
  pre-existing Testcontainers Redis deprecation.
- `xcodebuild test` for `LadleTests` with coverage disabled: 185 passed,
  1 skipped.
- `xcodebuild test` for `LadleUITests` with coverage disabled: 5 passed.
- The complete app and Share Extension simulator build passes. Visual review
  on iPhone 17 Pro confirms the two-column grid keeps artwork, titles, and
  nutrition facts aligned while retaining the compact image size.
- Known existing build warnings remain in Google Sign-In's callback sendability
  and a deprecated test-only `UIWindow(frame:)` initializer.
