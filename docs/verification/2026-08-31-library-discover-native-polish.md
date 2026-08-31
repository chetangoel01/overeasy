# Library and Discover: native chrome pass

Date: 2026-08-31 · Branch: `ui/watch-recipe-polish`
Commits: `9eb0d44`, `adb23e6`, `549ac9f`, `8c43070`

## Purpose

Six UI complaints, resolved as four coherent changes. The through-line is the
same in every case: the app was hand-drawing things iOS already provides, and
the hand-drawn versions were the parts that read as unpolished.

Direction was confirmed with Chetan before implementation (per AGENTS.md), and
two of the offered options turned out not to be supported by the code — both
are recorded below.

## 1. System search field (`9eb0d44`)

**Was:** a hand-rolled `TextField` inside the library's scroll content.

**Now:** `.searchable(placement: .navigationBarDrawer)` on `AllRecipesView`.

This fixes two reported problems at once:

- The search bar now docks under the large title and collapses on scroll, the
  way every other iOS app behaves. The large title collapses to inline with it.
- It no longer participates in the push transition. Recorded at 60fps, the old
  field slid left as a hard-edged pale slab beside the incoming photo for about
  12 frames — the "overlay that cuts into the screen". It now cross-fades in
  place with the navigation bar.

The 35-line `searchField` property is gone. Nothing referenced its
`library.search` accessibility identifier.

**Note on the transition:** what remains is standard iOS push parallax — a thin
sliver of the outgoing screen at the left edge, and the Liquid Glass toolbar
capsule cross-fading. Both are system behaviour, present in any iOS app. If the
overlay Chetan saw is still there after this, it is something else and needs a
fresh look.

## 2. Card facts (`9eb0d44`)

`"38 g P · ≈ 680 cal"` → `"680 cal · 38g protein"`.

Calories lead because that is the number people scan for; `g P` was cryptic.
The `≈` estimated marker is dropped from cards — it stays on the detail
screen's nutrition panel, which has room to explain what estimated means.

Covered by `LibraryViewModelTests`; four assertions updated first, then the
implementation.

## 3. Discover search and sort (`adb23e6`)

> **Superseded** by `2026-08-31-discover-paging.md`. The client-side search and
> the three-way sort described here lasted one commit: paging moved both to the
> server, because a search that only reads the loaded page returns "no results"
> while matches sit just outside it.

Discover had no way to narrow the feed at all. Added a system search field over
title, creator and description, and a sort menu in the toolbar.

**Scope correction.** The agreed direction was "search + sort (popular / recent
/ quickest)". `DiscoverRecipe` carries `savedCount` but **no publish date and no
cook time**, so *recent* and *quickest* have no data behind them. Sort ships as:

| Order | Basis |
| --- | --- |
| Featured | the service's own returned order (default) |
| Most saved | `savedCount` descending |
| A to Z | title |

*Recent* and *quickest* need `DiscoverRecipe` to grow those fields in
`RemoteContracts.swift` and the backend to populate them. Not attempted.

The feed subtitle now follows the chosen order instead of always claiming to be
ranked by saves. Empty search shows `ContentUnavailableView.search`. Search and
sort are client-side over the page already loaded.

## 4. Filter sheet as a native form (`549ac9f`)

**Was:** four hand-drawn chip grids, a bespoke toggle, and an
`ultraThinMaterial` bottom bar — each re-deriving spacing, grouping and
selection, which is what made it read as arbitrary.

**Now:** a standard grouped `Form` — toggle, Time section, Nutrition section
with a "Measured per serving." footer, and a Reset row that disables itself
when nothing is active. Apply and Cancel moved to the toolbar.

Filter semantics are unchanged: same thresholds, same apply and reset.
Removed `DecimalFilterSection`, `FilterSection`, `FilterChoices` and
`FilterChoiceButton`, about 120 lines.

`DesignTokenTests.testSheetToolbarControlsUseTheSemanticInset` dropped
`FilterSheet` from its list, with the reason recorded in the test: that inset
corrects for sheets laying out at `sheetMargin`, and a native `Form` sits on
system margins, so applying it would push the toolbar controls out of
alignment.

## 5. System text styles (`8c43070`)

**Correction to an earlier claim:** the app was already using SF Pro with
Dynamic Type, and screen titles were already real `.navigationTitle` large
titles. What was custom was the *size scale*.

Sizes were hand-picked (38/31/19/18) and scaled with `ScaledMetric` against a
related text style. That approximates iOS at the default Dynamic Type setting
and drifts everywhere else.

Every role is now a system text style directly:

| Role | Text style | Was | Now |
| --- | --- | --- | --- |
| `display` | `.largeTitle` | 38 | 34 |
| `title` | `.title` | 31 | 28 |
| `recipeTitle` | `.title3` | 18 | 20 |
| `section` | `.headline` | 19 | 17 |
| `body` / `bodyStrong` | `.body` | 17 | 17 |
| `metadata` | `.footnote` | 13 | 13 |
| `eyebrow` | `.caption` | 12 | 12 |

`section` and `body` no longer override the text style's own weight, so
`.headline` stays whatever iOS defines semibold to be.

Because every call site goes through `ladleFont(_:)`, this was one file plus
the `DESIGN.md` table. `ladleScaledFont(size:)` stays for Focus Mode's distance
legibility.

## Verification

- `LadleTests`: **352 passed, 0 failures**, 1 skipped.
- Full app + Share Extension build against the iOS 26.5 SDK: succeeded.
- Confirmed by screenshot on iPhone 17 / iOS 26.5: search collapse on scroll,
  new card facts, Discover sort menu, the rebuilt filter sheet, and the type
  scale across Library and Recipe Detail.
- Push transition re-recorded at 60fps before and after.

## Not done

- Nothing was checked on iOS 27 — see
  `2026-08-31-ios27-design-compatibility.md`. The Watch tab-bar contrast
  regression documented there is still open.
- `recent` / `quickest` Discover sorts, pending the contract fields.
