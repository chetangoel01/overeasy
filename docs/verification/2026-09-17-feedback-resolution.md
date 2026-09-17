# September 17 feedback resolution

Scope: all 22 open GitHub issues, confirmed by the owner on September 17, 2026.
Branch: `codex/feedback-resolution-2026-09-17`, based on `81b101d`.

Implementation proceeds in verified, task-sized commits. Design choices remain pending until the owner answers the in-task questions. Physical-device checks require a connected iPhone; both registered phones were disconnected at the initial check.

| Issue | Work | Status |
| --- | --- | --- |
| [#37](https://github.com/chetangoel01/overeasy/issues/37) | Fall back per ingredient when USDA has no usable record, instead of voiding the recipe | Pending |
| [#110](https://github.com/chetangoel01/overeasy/issues/110) | The dashboard's recent-requests poll counts in its own traffic charts | Implemented and verified |
| [#111](https://github.com/chetangoel01/overeasy/issues/111) | The USDA relevance gate refuses records it should accept: ghee, tomato, lentils, pancetta | Implemented and verified |
| [#113](https://github.com/chetangoel01/overeasy/issues/113) | A private or deleted photo carousel reports parserUnavailable and retries forever | Implemented and verified |
| [#117](https://github.com/chetangoel01/overeasy/issues/117) | Short links are invisible to the inbox repair and to the duplicate check | Implemented and verified |
| [#124](https://github.com/chetangoel01/overeasy/issues/124) | Saving an already-cached Discover recipe arrives untagged, and a persisted diet filter then hides it | Implemented and verified; production backfill pending |
| [#140](https://github.com/chetangoel01/overeasy/issues/140) | Keep loading and sync indicators from shifting the screen | Pending |
| [#141](https://github.com/chetangoel01/overeasy/issues/141) | Polish app motion with consistent native, tactile feedback | Pending |
| [#142](https://github.com/chetangoel01/overeasy/issues/142) | Define and enforce consistent button design rules | Pending |
| [#143](https://github.com/chetangoel01/overeasy/issues/143) | Explore recipe reviews and more visible likes and save counts | Pending |
| [#144](https://github.com/chetangoel01/overeasy/issues/144) | Add a calorie breakdown to nutrition per serving | Pending |
| [#145](https://github.com/chetangoel01/overeasy/issues/145) | Make recipe estimate notes quieter and less repetitive | Pending |
| [#146](https://github.com/chetangoel01/overeasy/issues/146) | Polish the app icon selector layout in Profile | Pending |
| [#147](https://github.com/chetangoel01/overeasy/issues/147) | Investigate the layout of the icon-change confirmation dialog | Pending |
| [#148](https://github.com/chetangoel01/overeasy/issues/148) | Adjust servings directly on the recipe without opening a sheet | Pending |
| [#149](https://github.com/chetangoel01/overeasy/issues/149) | Include vegetarian and vegan recipes in pescatarian filtering | Implemented and verified |
| [#150](https://github.com/chetangoel01/overeasy/issues/150) | Make the original video easy to access from recipe details | Pending |
| [#151](https://github.com/chetangoel01/overeasy/issues/151) | Reduce the large thumbnail at the top of recipe details | Pending |
| [#152](https://github.com/chetangoel01/overeasy/issues/152) | Find why total time still fails to show on some recipes | Pending |
| [#153](https://github.com/chetangoel01/overeasy/issues/153) | Show two Discover shelves up front and move the rest into the scroll | Pending |
| [#160](https://github.com/chetangoel01/overeasy/issues/160) | Show ingredient quantities in recipe Focus mode | Pending |
| [#161](https://github.com/chetangoel01/overeasy/issues/161) | Verify cooking timer completion plays a sound and shows an alert | Pending |

## Verification

- #117: server resolution and app duplicate/repair regressions verified red/green. 90 focused app tests, 67 focused backend tests, and all 1,133 backend tests passed.

- #124: regression verified red/green; 11 backfill tests and all 1,132 backend tests passed. Only cache tags are refreshed; original verified content is preserved.

- #111: wording, search-fallback, and food-form regressions verified red/green; 80 focused tests and all 1,129 backend tests passed. Live stored records were inspected read-only.

- #149 red: both new shared-domain tests failed; backend diet fixtures produced six expected failures for missing compatibility.
- #110: regression failed before the fix; 21 focused tests and the full 1,112-test backend suite passed afterward. Running the dashboard's actual aggregation with 3 app requests and 12 polls changed the displayed total from 15 to 3.
- #113: four regressions failed before the change; 15 focused tests and all 1,117 backend tests passed afterward.
- #149 green: all 91 shared-domain tests and 28 backend Discover/filter/shelf tests passed. Full backend suite: 1,111 passed.

No issues are considered complete solely because an implementation exists; unresolved device checks and product decisions remain explicit.
