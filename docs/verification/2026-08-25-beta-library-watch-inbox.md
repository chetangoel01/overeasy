# Beta library, Watch, Inbox, and nutrition release

Date: August 25, 2026

## Purpose

Ship the outstanding beta feedback as one coherent TestFlight update: make
processing safely dismissible, distinguish closing from cancellation, keep
saved discoveries gone, repair the compact recipe grid, offer alternate library
views, clarify the four-tab workspace, and make useful nutrition visible
without overwhelming the recipe.

The corrective release build number is `20260825.2`.

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
- Watch owns one persistent feed selector above the video pages. Switching to
  Discover refreshes the feed, failure offers an explicit retry, and feed type
  participates in deciding whether a recipe uses saved or Discover actions so
  matching recipe identifiers cannot leave the wrong feed on screen.
- Grid artwork is laid out by a square container before the source image is
  cropped. Portrait and landscape sources therefore cannot change card height
  or stagger the next row.
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
- `xcodebuild test` for `LadleUITests` with coverage disabled: 6 passed.
- The complete app and Share Extension simulator build passes. Visual review
  on iPhone 17 Pro confirms the two-column grid keeps artwork, titles, and
  nutrition facts aligned while retaining the compact image size.
- Known existing build warnings remain in Google Sign-In's callback sendability
  and a deprecated test-only `UIWindow(frame:)` initializer.

## Live beta deployment

- The first direct phone install used the Debug configuration, whose
  `api.ladle.localhost` address is intentionally reachable only from the Mac
  and simulator. That caused network-backed phone screens to report that they
  could not connect.
- Before correcting the install, the existing VPS database and media were
  backed up and verified at `20260825T211557Z`.
- Backend revision `ec80c4ac5fc5a074141f001b15cfb1c5a9d77d1c` was deployed to
  the guarded HTTPS VPS route, including migration `0014`. API readiness and a
  live worker ping both passed after deployment.
- A signed Release build of `20260825.1` was verified to contain the HTTPS API
  address and guarded access configuration, then installed over the Debug copy
  on Chetan's iPhone without removing application data.
- The corrected app launched successfully. Its first sync refreshed the
  existing account session and retried `GET /v1/recipes/sync`, which returned
  `200`, confirming end-to-end phone-to-production connectivity.

## Corrective grid and Watch pass

- Build `20260825.2` fixes the beta screenshot regression where source image
  proportions stretched individual grid cards and staggered later rows.
- Watch's My Recipes and Discover segments now switch the actual content and
  actions even when the same recipe identity exists in both snapshots. The
  Discover segment also reloads its snapshot when selected and exposes a retry
  action after a failed request.
- Focused UI coverage measures the first two grid rows and verifies both cards
  in each row share the same position and height. A separate interaction test
  verifies My Recipes removes the Discover Save action and switching back
  restores it.
- Simulator visual review confirms portrait and landscape artwork are cropped
  into equal squares and subsequent rows remain aligned. The complete six-test
  UI suite passes on iPhone 17 Pro.
- All 185 runnable `LadleTests` pass with the one existing intentional skip.
  A signed Release build also passes embedded Share Extension validation and
  contains the production HTTPS endpoint and guarded access configuration.
- Signed build `20260825.2` was installed over the previous copy on Chetan's
  iPhone without deleting application data.
