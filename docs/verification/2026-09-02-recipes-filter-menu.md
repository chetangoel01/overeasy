# Recipes filters are a menu, not a sheet

Date: September 2, 2026
Issue: [#63](https://github.com/chetangoel01/recipe-app/issues/63)
Status: **built and verified on the review simulator.**

## Purpose

Filtering the library cost a full-screen sheet, a staged copy of every
filter, and an Apply button — for six controls that sit two taps from the
recipes they narrow. Sort and Recipe view, immediately beside Filters in the
same header, had already been rebuilt as menus of inline pickers on
[September 1](2026-09-01-recipes-pickers.md). Filters is now the third one,
so the three header controls are the same control.

## What the cook sees

- **Filters is a menu.** Tapping it opens the system menu under the header
  rather than covering the library. The glyph still fills to
  `line.3.horizontal.decrease.circle.fill` while any filter is on, and
  VoiceOver still reads "Filters" or "Filters 2".
- **Favorites is a checkmark row.** Tapping it applies at once. The menu
  dismisses on that tap — that is what iOS menus do, and it is not fought
  with `menuActionDismissBehavior`.
- **Five submenus, one per dimension:** Time, Calories, Protein,
  Carbohydrates, Fat. Each label carries its own current value — "Time · Any"
  until something is chosen, then "Time · 30 min or less" — so the whole
  filter state reads without opening a single submenu.
- **Each submenu is an inline picker** with "Any" first, then its options.
  Choosing one writes the view model directly, so the grid narrows on the tap.
  There is no Apply and nothing to forget to press; there is no Cancel,
  because every pill under the header undoes exactly one filter.
- **Reset filters appears only when something is on**, below a divider at the
  end of the menu.
- **The pills row is unchanged**: still the visible state, still the way to
  drop one filter.

## Decisions

- **A (menu with inline pickers), over B (a chip rail) and C (a shorter
  sheet).** The issue offered all three. A is the only one that makes Filters
  the same control as the two beside it; B replaces the header trio with a
  second row of controls, and C keeps a sheet for something that is now four
  taps end to end.
- **Reset is the trailing section, and absent rather than disabled.** A menu
  draws a disabled destructive row badly. Putting it last means the rows above
  it never move when it appears, so the top of the menu is stable whether or
  not a filter is on.
- **The submenu label carries its value.** A `Menu` title is a plain string,
  so "Time · 30 min or less" is the only way to show a submenu's state without
  opening it. The alternative — five submenus all reading "Time", "Calories",
  … — would make the menu a set of doors with nothing written on them.
- **Filters do not persist across launches.** They never did:
  `-reset-library-preferences` covers the display mode and the two collapse
  flags, and the six filters have always started empty. Making a menu of them
  is not a reason to change that.
- **One shared option source.** `LibraryFilter` owns the option lists and the
  words for every value, and both the picker rows and the pills read it, so a
  value cannot be named one thing on the checked row and another on the pill
  that removes it. `LibraryFilterChip.chips(for:)` moved out of the view for
  the same reason — it is the only way the equality is testable.
- **Accepted cost: the pills lost their dimension word.** They used to read
  "Up to 600 cal" and "Under 50 g carbs"; they now read "600 or fewer" and
  "Under 50 g", because those are the words the menu row uses and the whole
  point is that the two agree. Time and the gram filters stay clear on their
  own; "600 or fewer" is the one pill that does not say what it counts. The
  cheap fix would be to word calories "600 cal or fewer" in both places, which
  is a one-line change to `LibraryFilter.optionTitle` if it reads wrong in use.
- **`Decimal` filters bridge to `Int` rather than tagging five times.** The
  brief asked for the sheet's `decimalPicker` idea — one shared optional
  tagging helper — to survive. It survives as `wholeNumber(_:)`, a
  `Binding<Decimal?>` → `Binding<Int?>` bridge, because every option any
  filter can take is a whole number: one picker row builder then serves all
  five submenus instead of two near-identical ones.
- **Reset leaves the selected collection alone.** A collection is navigation,
  not a filter, and the menu never offers it — so `hasActiveFilters` and
  `resetFilters()` are about the six the menu owns. The filter *count* on the
  button and the pills row still include the collection chip, as before.

## Affected components

| File | Change |
|------|--------|
| `Ladle/Library/LibraryFilter.swift` | new: the option lists, the wording, `menuTitle(for:)`, and `LibraryFilterChip` with `chips(for:)` |
| `Ladle/Library/AllRecipesView.swift` | Filters `Button` → `filterMenu`; `filterSubmenu(_:selection:)` and `wholeNumber(_:)`; `filterChips` forwards to the shared source; `appendNumericFilters` and the private chip type deleted; `presentFilters` parameter dropped |
| `Ladle/Library/LibraryViewModel.swift` | `hasActiveFilters` and `resetFilters()` added; `showCollection` delegates to the latter |
| `Ladle/Library/LibraryView.swift` | `isFilterSheetPresented`, its `.sheet`, and the `presentFilters:` argument removed |
| `Ladle/Library/FilterSheet.swift` | deleted |
| `Ladle/Account/AccountSheet.swift` | doc comment no longer points at the deleted sheet |
| `Ladle.xcodeproj/project.pbxproj` | `xcodegen generate` for the deletion and the three new files |
| `LadleTests/LibraryFilterTests.swift` | new |
| `LadleTests/DesignTokenTests.swift` | `testRecipesHeaderMenusAreNativePickers` now expects three menus |
| `LadleUITests/RecipesFilterMenuUITests.swift` | new |

## Verification

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,id=54720038-6397-4145-B02F-8C9B639C69FE' \
  -only-testing:LadleTests -only-testing:LadleUITests/RecipesFilterMenuUITests
```

- LadleTests: `Executed 423 tests, with 1 test skipped and 0 failures (0 unexpected) in 4.340 (4.500) seconds`
- LadleUITests/RecipesFilterMenuUITests: `Executed 1 test, with 0 failures (0 unexpected) in 18.552 (18.554) seconds`

Run in the background with the `Executed …` lines read from the log, because
`xcodebuild test` has hung after printing its results on this machine before.
This run did reach `** TEST SUCCEEDED **` and exit on its own.

`swift test --package-path Packages/LadleCore` was not run: the package is
untouched — `RecipeQuery` already applied all six filters and still does.

### The tests

Written first. `LibraryFilterTests` did not compile, because `LibraryFilter`,
`LibraryFilterChip.chips(for:)`, `hasActiveFilters` and `resetFilters()` did
not exist yet.

- `LibraryFilterTests` pins every option and every option's wording, the
  "Time · Any" submenu title, and — the one that matters — that the pill for
  an active filter is titled with `LibraryFilter.optionTitle` for the same
  value. It also asserts a pill removes only its own filter and that Reset
  spares the selected collection.
- `RecipesFilterMenuUITests` drives the real menu on the demo library: open
  Filters, open Time, choose "30 min or less", and the header count goes from
  "6 recipes" to "3 recipes" (the six demo recipes run 25/35/15/45/10/40
  minutes). Then it taps the pill and the count returns to "6 recipes".
- `DesignTokenTests.testRecipesHeaderMenusAreNativePickers` grew with the
  header: three `Menu`s, three `.menuOrder(.fixed)`, and three `Picker(`
  literals — one each for sort and view, one shared by the five filter
  submenus. It also pins the live `Favorites` binding, so a staged copy cannot
  come back.

Not run: the rest of `LadleUITests`.
`DiscoverInteractionUITests.testDiscoverRecipeSupportsTapAndLongPress` is
already failing on `main` for an unrelated reason, tracked as
[#65](https://github.com/chetangoel01/recipe-app/issues/65).

## Evidence

Captures from Debug builds on the "Overeast UI validation" simulator
(`614AF85D-84AF-4371-BF70-5D5DA2BBA683`, iPhone 17 Pro, iOS 26.5), launched
with `-ui-testing -onboarding-complete -reset-library-preferences` and driven
by scripted taps. The status bar was frozen with `simctl status_bar override`
and cleared afterwards.

| | |
|---|---|
| [before-filter-sheet.png](captures/2026-09-02-recipes-filter-menu/before-filter-sheet.png) | what Filters used to open: a full-screen `Form` behind Cancel and Apply |
| [after-menu-open.png](captures/2026-09-02-recipes-filter-menu/after-menu-open.png) | the menu — Favorites, then the five submenus, each labelled with its value |
| [after-time-submenu.png](captures/2026-09-02-recipes-filter-menu/after-time-submenu.png) | Time expanded and now labelled "Time · 30 min or less", with that row checked |
| [after-filter-active.png](captures/2026-09-02-recipes-filter-menu/after-filter-active.png) | menu dismissed: "3 recipes", the "30 min or less" pill, the filled filter glyph |
