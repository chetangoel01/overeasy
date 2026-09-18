# September 17 feedback resolution

Scope: all 22 open GitHub issues, confirmed by the owner on September 17, 2026.
Branches: `codex/feedback-resolution-2026-09-17` (based on `81b101d`), then one `codex/feedback-…` branch per issue group; all merged to `main` on September 17.

Implementation proceeds in verified, task-sized commits. The owner answered the open product questions on September 17 — the layout group from a live mockup — and those changes are implemented below. Physical-device checks require a connected iPhone. Both were initially disconnected; the iPhone 17 Pro later became reachable and reports Overeasy build `20260910.2`. Audible delivery is still unverified.

| Issue | Work | Status |
| --- | --- | --- |
| [#37](https://github.com/chetangoel01/overeasy/issues/37) | Fall back per ingredient when USDA has no usable record, instead of voiding the recipe | Existing behavior audited and verified; paid provider remains deferred |
| [#110](https://github.com/chetangoel01/overeasy/issues/110) | The dashboard's recent-requests poll counts in its own traffic charts | Implemented and verified |
| [#111](https://github.com/chetangoel01/overeasy/issues/111) | The USDA relevance gate refuses records it should accept: ghee, tomato, lentils, pancetta | Implemented and verified |
| [#113](https://github.com/chetangoel01/overeasy/issues/113) | A private or deleted photo carousel reports parserUnavailable and retries forever | Implemented and verified |
| [#117](https://github.com/chetangoel01/overeasy/issues/117) | Short links are invisible to the inbox repair and to the duplicate check | Implemented and verified |
| [#124](https://github.com/chetangoel01/overeasy/issues/124) | Saving an already-cached Discover recipe arrives untagged, and a persisted diet filter then hides it | Implemented and verified; production backfill pending |
| [#140](https://github.com/chetangoel01/overeasy/issues/140) | Keep loading and sync indicators from shifting the screen | Implemented and verified |
| [#141](https://github.com/chetangoel01/overeasy/issues/141) | Polish app motion with consistent native, tactile feedback | Implemented and verified |
| [#142](https://github.com/chetangoel01/overeasy/issues/142) | Define and enforce consistent button design rules | Implemented and verified |
| [#143](https://github.com/chetangoel01/overeasy/issues/143) | Explore recipe reviews and more visible likes and save counts | Owner chose existing counts plus star ratings; [API](2026-09-17-recipe-ratings-api.md) and [iOS surfaces](2026-09-17-recipe-ratings-ios.md) implemented, verified and merged; not deployed, so no request has met a live server |
| [#144](https://github.com/chetangoel01/overeasy/issues/144) | Add a calorie breakdown to nutrition per serving | Macro breakdown implemented and verified; by-ingredient deferred |
| [#145](https://github.com/chetangoel01/overeasy/issues/145) | Make recipe estimate notes quieter and less repetitive | Implemented and verified |
| [#146](https://github.com/chetangoel01/overeasy/issues/146) | Polish the app icon selector layout in Profile | Implemented and verified; the confirmation dialog itself remains #147 |
| [#147](https://github.com/chetangoel01/overeasy/issues/147) | Investigate the layout of the icon-change confirmation dialog | System ownership confirmed; physical reproduction pending |
| [#148](https://github.com/chetangoel01/overeasy/issues/148) | Adjust servings directly on the recipe without opening a sheet | Implemented and verified |
| [#149](https://github.com/chetangoel01/overeasy/issues/149) | Include vegetarian and vegan recipes in pescatarian filtering | Implemented and verified |
| [#150](https://github.com/chetangoel01/overeasy/issues/150) | Make the original video easy to access from recipe details | Implemented and verified |
| [#151](https://github.com/chetangoel01/overeasy/issues/151) | Reduce the large thumbnail at the top of recipe details | Implemented and verified |
| [#152](https://github.com/chetangoel01/overeasy/issues/152) | Find why total time still fails to show on some recipes | Implemented and verified; production backfill pending |
| [#153](https://github.com/chetangoel01/overeasy/issues/153) | Show two Discover shelves up front and move the rest into the scroll | Implemented and verified |
| [#160](https://github.com/chetangoel01/overeasy/issues/160) | Show ingredient quantities in recipe Focus mode | Implemented and verified |
| [#161](https://github.com/chetangoel01/overeasy/issues/161) | Verify cooking timer completion plays a sound and shows an alert | Permission-delay defects fixed; physical sound/alert checks pending |

## Verification

- #143 (iOS): likes ride the header's source line; stars and saves take their own line on the header, Discover rows and Watch; a saved recipe with a source gets a rating card above Start cooking, optimistic with rollback. Four new app tests were each seen failing first (two against the old sync code, two by mutation), beside fixture assertions. Existing recipes learn `sourceID` from a pull from the start of the log, repeated once per launch until one carries a source; without the API the app makes no engagement request and shows nothing. Captured in dark, light and the largest text size. Not run against a server or on a phone; VoiceOver not listened to. [Ratings on iOS](2026-09-17-recipe-ratings-ios.md).
- #151: on the old layout the nutrition card ended 76 points under the tab bar (866.7 against 791); that first-screen assertion failed there and now passes inside the scaling smoke journey. At accessibility sizes the thumbnail stacks above the title. Captured in dark, light and the largest text size. [Recipe details layout](2026-09-17-recipe-details-layout.md).
- #150: the link and the play-badged thumbnail appear only when `VideoEmbed.url(for:)` accepts the link, on saved recipes and Discover previews, which had no path to the player before; the menu entry is gated the same way. By hand, the player opens from both places, the reading position is kept, and a hand-typed recipe shows no dead control. [Recipe details layout](2026-09-17-recipe-details-layout.md).
- #148: inline minus, count and plus with "servings · Reset"; `ServingsSheet` is deleted. Red on the old layout (2 failures), and the smoke journey passes. Everything under the band is pixel-identical unscaled and scaled. VoiceOver gets one adjustable element and one settled announcement. [Recipe details layout](2026-09-17-recipe-details-layout.md).
- #145: the accent time note and the "Estimated" pill are removed; routine `nutritionAmount` assumptions moved into one collapsed "About these estimates" row; "Not counted" and extraction doubts stay on their rows in neutral type. The list test was red against a shell (2 failures). [Recipe details layout](2026-09-17-recipe-details-layout.md).
- #153: two shelves now lead Discover and the rest sit in the ranked list, one after every third row, with leftovers after the last row once the list ends. Which two lead is drawn once per launch from the rails and keyword shelves alike and holds through a pull, a tab switch, a filter change and the New recipes page; a lead that is empty, filtered out, under three cards or failed hands its slot to the next shelf. Demo and UI-test runs draw nothing, so the rails lead there. Looking at it found a lazy-stack fault — after a save changed the lead shelves mid-scroll the viewport jumped — fixed by keeping only the rows lazy. [Two shelves lead Discover](2026-09-17-discover-two-shelves.md); the rule is in [DESIGN.md](../../DESIGN.md#discover-and-account).
- #160: a new view-model test failed red (two assertions) then passed; amounts under "For this step" share Full Recipe's rule, a reused ingredient shows its recipe total and says so, and a small fold holds for the cooking session. [Focus step amounts](2026-09-17-focus-step-amounts.md).
- #146: one sideways-scrolling row, ring plus caption check, a list at accessibility sizes. On the owner's instruction to cut UI tests, the seven-icon switching test became one check that the last icon in the row can be reached and chosen through the real system switch; the store's persistence stays with `AppIconStoreTests`. [App icon picker](2026-09-17-app-icon-picker.md).
- Combined check after every branch landed: all 598 app tests pass on the merged code (one intentional skip), with the four smoke journeys — Discover tap and long-press, scaling, inbox → detail → cooking, and the icon row.
- #144: the owner chose the macro breakdown on September 17; calories by ingredient is deferred because it needs per-ingredient figures from the pipeline. Shares that add to 100 and the rule that the macro sum is never reconciled with the stated calories were both verified red/green. Protein's dot and bar segment had used the success fill, which all but vanished in dark mode (1.3:1 on the hero); they now use a `Mark.protein` colour, and a contrast test, red first, holds all three macro marks to 3:1 on the hero and the tiles in both appearances. 95 shared-domain tests and 592 app tests pass (one intentional skip), as does the UI check that opens the sheet. Light, dark and largest-text captures are in the [macro calorie breakdown](2026-09-17-macro-calorie-breakdown.md).
- #140: the owner chose to hide routine sync entirely. A hosted regression measured the "Syncing recipes…" and "Refreshing Discover…" strips at 36 points each inside the top safe-area inset, which is what pushed every screen down and back; it now measures zero for routine work and still measures the failed strips. The tall empty header reproduced as a second defect: every strip's fill painted up under the clear navigation bar and covered the large title, on the failure strips and the New recipes pill too; the fill now stops at the strip. The placeholders already kept the normal chrome and nothing moves when the feed arrives. All 591 app tests pass (one intentional skip), and both UI scenarios that expect the failed-sync strip pass. Decision, causes, captures, and what was left alone are in [quiet sync and refresh](2026-09-17-quiet-sync.md); the rule is in [DESIGN.md](../../DESIGN.md#motion-and-feedback).

- #141: a hosted SwiftUI probe reproduced a forced 0.5-second save animation outside the presenting view. The save model now publishes state without dictating motion; RecipeDetail, Discover, and FullRecipe consult Reduce Motion for their explicit save and scroll transitions. The hosted regression passes, and all 590 app tests pass (one intentional skip). Existing press and haptic behavior was audited and is documented in [DESIGN.md](../../DESIGN.md#motion-and-feedback).

- #142: Discover Save measured 75→38 points wide while loading (137→55 at accessibility text), and used 44-point height. The actual rendered-control regression now passes at standard, AX3, and AX5 sizes with stable bounds and the shared 52-point minimum. 93 focused app tests pass. The Discover save, retry alignment, and largest-text save UI checks pass. Shared loading also covers retry and Health export; toolbar Save reserves its label. Favorites share the icon control, retaining material only over photos. Rules and exceptions are recorded in [DESIGN.md](../../DESIGN.md#buttons).

- #143 (API only): the rating lifecycle, merge tie-break and migration tests were each seen failing first. All 1,141 backend tests, lint and strict type checks pass, and the 91 shared-domain tests still pass against the updated fixtures. See [ratings API](2026-09-17-recipe-ratings-api.md).

- #161: two permission-delay defects verified red/green. All 27 focused cooking/notification tests and the full 588-test app suite passed (one intentional skip). Physical listening remains pending; see [timer alerts](2026-09-17-timer-alerts.md).

- #152: production gaps traced read-only to three stale shared templates and one legacy row. Thirty focused timing tests and all 1,143 backend tests pass. New imports repair missing totals once; admin backfill includes shared templates.

- #117: server resolution and app duplicate/repair regressions verified red/green. 90 focused app tests, 67 focused backend tests, and all 1,133 backend tests passed.

- #124: regression verified red/green; 11 backfill tests and all 1,132 backend tests passed. Only cache tags are refreshed; original verified content is preserved.

- #111: wording, search-fallback, and food-form regressions verified red/green; 80 focused tests and all 1,129 backend tests passed. Live stored records were inspected read-only.

- #149 red: both new shared-domain tests failed; backend diet fixtures produced six expected failures for missing compatibility.
- #110: regression failed before the fix; 21 focused tests and the full 1,112-test backend suite passed afterward. Running the dashboard's actual aggregation with 3 app requests and 12 polls changed the displayed total from 15 to 3.
- #113: four regressions failed before the change; 15 focused tests and all 1,117 backend tests passed afterward.
- #149 green: all 91 shared-domain tests and 28 backend Discover/filter/shelf tests passed. Full backend suite: 1,111 passed.

No issues are considered complete solely because an implementation exists; unresolved device checks and product decisions remain explicit.

## Decisions and device checks still pending

The owner has approved backend short-link resolution and bounded missing-time
repair including cached templates. On September 17 the owner also chose to
hide routine sync status entirely (#140) rather than move it into the
navigation bar, and macros over ingredient contributions for the calorie
breakdown (#144), which stay deferred; all four are implemented above. On the
same day the owner approved the layout group (#145, #146, #148, #150, #151,
#153, #160) from a live mockup — the Watch original link under the byline, the
second servings design, random lead shelves per relaunch, and a small fold on
Focus mode's ingredient list — and those are implemented above too. What
remains:

- Engagement (#143): built end to end but not live. It needs the backend
  deployed with migration `0027`; until then the app shows no engagement line
  and no rating card, by design. One engineering call awaits the owner: a
  rating currently outlives the deletion of the saved copy. Once the API has
  been live for a release, the launch-time replay that teaches older recipes
  their `sourceID` can be deleted.
- Phone QA (#147, #161): reproduce the system icon confirmation, and listen
  for the timer in the foreground and with the phone locked, recording Silent
  mode and Focus. Mirroring ultimately reports “iPhone in Use”. No listening
  result has been supplied and the installed TestFlight build predates these
  fixes. Repeat final timer checks on a build containing the changes.

## Current checkpoint

- Merged to `main` on September 17: the CI repairs ([#164](https://github.com/chetangoel01/overeasy/pull/164)), dashboard polling ([#162](https://github.com/chetangoel01/overeasy/pull/162)), the feedback fixes ([#163](https://github.com/chetangoel01/overeasy/pull/163)), the ratings API ([#165](https://github.com/chetangoel01/overeasy/pull/165)), quiet sync ([#166](https://github.com/chetangoel01/overeasy/pull/166)), the macro calorie breakdown ([#167](https://github.com/chetangoel01/overeasy/pull/167)), two Discover shelves ([#168](https://github.com/chetangoel01/overeasy/pull/168)), Focus amounts and the icon row ([#169](https://github.com/chetangoel01/overeasy/pull/169)), recipe details ([#170](https://github.com/chetangoel01/overeasy/pull/170)), and ratings on iOS ([#175](https://github.com/chetangoel01/overeasy/pull/175)), plus five dependency bumps. The test-suite cut the owner asked for landed as [#172](https://github.com/chetangoel01/overeasy/pull/172) (backend), [#173](https://github.com/chetangoel01/overeasy/pull/173) (app) and [#174](https://github.com/chetangoel01/overeasy/pull/174) (the rule in `AGENTS.md`). `main`'s backend gate is green for the first time since September 14. No security gate was relaxed.
- Final combined check on the merged code: the app unit suite (one intentional skip, no failures), all eight smoke UI journeys, the shared-domain tests and the backend suite with lint and type checks pass. The suites were cut down the same day on the owner's instruction — UI tests from 49 to eight smoke journeys — and the [trim record](2026-09-17-test-suite-trim.md) says what is no longer covered automatically.
- Deployed on September 18 (UTC): `Backend/deploy/vps/push.sh` shipped
  `7403068` (main after #181) to the VPS after a `manage.sh backup`
  (`ladle-20260918T050922Z`, Postgres dump and MinIO archive both verified).
  The `migrate` service applied `0027`; `/health/ready` reports every check
  ready on the new code, and `/v1/recipes/discover/<id>/engagement` answers
  401 where the old server answered 404. TestFlight build `20260918.1`
  (marketing 1.0) validated, uploaded and processed the same night; internal
  testing state `IN_BETA_TESTING`, external `READY_FOR_BETA_SUBMISSION`.
- Backfills, all run on the host on September 18 after the owner allowed the
  session to reach the VPS: `backfill-times` considered 20 recipes and shared
  templates and wrote 19 (one "Unknown Recipe" got no estimate);
  `backfill_tags` considered 51 recipes and tagged 33, leaving the already
  tagged ones unchanged; `refresh_recipe_nutrition.py --apply` ran once per
  account, 19 accounts, 51 recipes applied, none failed. Two lessons are
  recorded here so they are not repeated: the tag backfill and the nutrition
  refresh must not run at the same time (each rewrites the same recipe graph
  in its own transaction, and running them together produced a duplicate
  `pk_nutrition` on two accounts, which the rerun alone did not), and the
  refresh script dropped a recipe's other-nutrient rows until #184 made it
  write them back — the final rerun used the fixed script, so every refreshed
  recipe carries them.
- The owner's first full `backfill-times` run crashed before writing anything:
  a live extraction-cache row written before `nutrition.basis` existed failed
  validation against today's `RecipeTemplate`, whose `basis` was required.
  The same strict read sits on the import cache-hit path and on Discover
  saves of that source. `basis` now defaults to `"unknown"` on the stored
  template model (nothing reads it on the way out), with a unit test that an
  old-shape row loads and instantiates; the fix was deployed before the
  backfills were retried.
- The phone checks for #147 and #161 were done on a development build of
  `main` on September 17 (see #161); the timer-related changes since are in
  `2026-09-17-cooking-session-timers.md` and
  `2026-09-17-live-activity-timers.md`.
