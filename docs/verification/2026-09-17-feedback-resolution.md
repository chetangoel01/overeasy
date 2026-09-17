# September 17 feedback resolution

Scope: all 22 open GitHub issues, confirmed by the owner on September 17, 2026.
Branch: `codex/feedback-resolution-2026-09-17`, based on `81b101d`.

Implementation proceeds in verified, task-sized commits. Design choices remain pending until the owner answers the in-task questions. Physical-device checks require a connected iPhone. Both were initially disconnected; the iPhone 17 Pro later became reachable and reports Overeasy build `20260910.2`. Audible delivery is still unverified.

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
| [#143](https://github.com/chetangoel01/overeasy/issues/143) | Explore recipe reviews and more visible likes and save counts | Pending |
| [#144](https://github.com/chetangoel01/overeasy/issues/144) | Add a calorie breakdown to nutrition per serving | Pending |
| [#145](https://github.com/chetangoel01/overeasy/issues/145) | Make recipe estimate notes quieter and less repetitive | Pending |
| [#146](https://github.com/chetangoel01/overeasy/issues/146) | Polish the app icon selector layout in Profile | Pending |
| [#147](https://github.com/chetangoel01/overeasy/issues/147) | Investigate the layout of the icon-change confirmation dialog | System ownership confirmed; physical reproduction pending |
| [#148](https://github.com/chetangoel01/overeasy/issues/148) | Adjust servings directly on the recipe without opening a sheet | Pending |
| [#149](https://github.com/chetangoel01/overeasy/issues/149) | Include vegetarian and vegan recipes in pescatarian filtering | Implemented and verified |
| [#150](https://github.com/chetangoel01/overeasy/issues/150) | Make the original video easy to access from recipe details | Pending |
| [#151](https://github.com/chetangoel01/overeasy/issues/151) | Reduce the large thumbnail at the top of recipe details | Pending |
| [#152](https://github.com/chetangoel01/overeasy/issues/152) | Find why total time still fails to show on some recipes | Implemented and verified; production backfill pending |
| [#153](https://github.com/chetangoel01/overeasy/issues/153) | Show two Discover shelves up front and move the rest into the scroll | Pending |
| [#160](https://github.com/chetangoel01/overeasy/issues/160) | Show ingredient quantities in recipe Focus mode | Pending |
| [#161](https://github.com/chetangoel01/overeasy/issues/161) | Verify cooking timer completion plays a sound and shows an alert | Permission-delay defects fixed; physical sound/alert checks pending |

## Verification

- #140: the owner chose to hide routine sync entirely. A hosted regression measured the "Syncing recipes…" and "Refreshing Discover…" strips at 36 points each inside the top safe-area inset, which is what pushed every screen down and back; it now measures zero for routine work and still measures the failed strips. 116 focused app tests pass, and both UI scenarios that expect the failed-sync strip pass. Decision, causes, and what was left alone are in [quiet sync and refresh](2026-09-17-quiet-sync.md); the rule is in [DESIGN.md](../../DESIGN.md#motion-and-feedback).

- #141: a hosted SwiftUI probe reproduced a forced 0.5-second save animation outside the presenting view. The save model now publishes state without dictating motion; RecipeDetail, Discover, and FullRecipe consult Reduce Motion for their explicit save and scroll transitions. The hosted regression passes, and all 590 app tests pass (one intentional skip). Existing press and haptic behavior was audited and is documented in [DESIGN.md](../../DESIGN.md#motion-and-feedback).

- #142: Discover Save measured 75→38 points wide while loading (137→55 at accessibility text), and used 44-point height. The actual rendered-control regression now passes at standard, AX3, and AX5 sizes with stable bounds and the shared 52-point minimum. 93 focused app tests pass. The Discover save, retry alignment, and largest-text save UI checks pass. Shared loading also covers retry and Health export; toolbar Save reserves its label. Favorites share the icon control, retaining material only over photos. Rules and exceptions are recorded in [DESIGN.md](../../DESIGN.md#buttons).

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
repair including cached templates, and on September 17 chose to hide routine
sync status entirely (#140) rather than move it into the navigation bar; all
three are implemented above. These earlier questions remain unanswered, so
their dependent product changes have not been selected on the owner's behalf:

- Layout group (#145, #146, #148, #150, #151, #153, #160): proposed compact
  thumbnail header with “Watch original”; inline serving minus/plus and Reset;
  neutral expandable estimate notes; horizontal icon choices with a list for
  accessibility text; two randomly selected top shelves per launch with the
  others between feed rows; Focus quantities under “For this step”, explicitly
  labelled as recipe totals when an ingredient is reused across steps.
- Engagement (#143): expose source-platform likes and Overeasy saves only,
  or add ratings, or ratings with written reviews. Public feedback needs its
  contribution/edit/report rules once that scope is selected.
- Calorie breakdown (#144): macros, ingredient contributions, or both.
- Phone QA (#147, #161): reproduce the system icon confirmation, and listen
  for the timer in the foreground and with the phone locked, recording Silent
  mode and Focus. Mirroring ultimately reports “iPhone in Use”. No listening
  result has been supplied and the installed TestFlight build predates these
  fixes. Repeat final timer checks on a build containing the changes.

## Current review checkpoint

- [Draft PR #163](https://github.com/chetangoel01/overeasy/pull/163) contains the feedback fixes.
- Dashboard polling has its own [draft PR #162](https://github.com/chetangoel01/overeasy/pull/162).
- Both are stacked on [draft PR #164](https://github.com/chetangoel01/overeasy/pull/164), which repairs pre-existing CI failures: the removed MinIO Docker Hub image and three fixed PCRE2 findings. The new registry passes the storage integration checks; the backend, ingress and egress images build with zero fixable HIGH/CRITICAL scan findings. The locked dependency audit is clean. No security gate was relaxed.
- Backend: 1,137 passing tests after the owner's requested test cleanup; 89
  focused checks, lint, and type checks also pass. Six weak tests and repeated
  implementation assertions were removed; the
  [test maintenance record](../../Backend/docs/ci-and-production-verification.md#test-maintenance)
  records the scope and the revised guidance. Product behavior is unchanged.
- App: 590 tests, one intentional skip, no failures. App and Share Extension
  compile in that run. Shared domain: 91 passing tests after the filter change.
- Three affected UI checks pass: Discover save, retry alignment, and AX5 Save.
- Xcode changed from 26.6 to 27.0 during verification. A simulator component
  update and a reboot of the dedicated test simulator resolved the transient
  runner failures; the final full app run used Xcode 27.0 on iOS 26.5.
- Production has been inspected read-only. Deployment and existing-data tag,
  timing, and nutrition refreshes have not been performed.
