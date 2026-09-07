# One filter, three tabs

Date: September 7, 2026
Issue: [#87](https://github.com/chetangoel01/recipe-app/issues/87)
Status: **built and verified on the review simulator.**

The iOS half of #87. The backend half is
[#105](https://github.com/chetangoel01/recipe-app/pull/105) and its write-up
is [2026-09-07-recipe-tags.md](2026-09-07-recipe-tags.md); nothing in
`Backend/` is touched here.

## Purpose

Sagrika scrolled past ten chicken videos to find one vegetarian recipe. #105
gave a recipe a diet, a cuisine and keywords and taught Discover to filter on
them. This is the part she touches: one filter state, one control, and three
tabs that answer it — the library from the tags it already holds, Discover
and Watch from the server.

The Recipes filter menu from
[#63](2026-09-02-recipes-filter-menu.md) is rebuilt onto that shared state
rather than left beside it. There is one filter control in the app.

## What the cook sees

- **Filters is the same menu on Recipes, Discover and Watch.** Diet is the
  first section, five toggles, not behind a submenu — it is the family that
  survives the launch, so it is the one whose state has to be readable
  without opening anything. Cuisine, Keywords and Ingredients follow as
  submenus whose labels carry their own count ("Cuisine · Any", "Cuisine · 2").
- **Ingredients is a list of terms, not a search box.** "Add ingredient…"
  opens a system alert with one field; a term becomes a checked row that
  removes itself on tap. Ten terms of a hundred characters is the server's
  limit and it is enforced here, so a cook is stopped by a full list rather
  than by a 422 that would read as an empty app.
- **Diet comes back next launch. Nothing else does.** A diet is who the cook
  is; a cuisine or a keyword is what they are browsing for this evening, and
  a browse that silently resumed a week later would read as an app with
  recipes missing.
- **A pill for everything that is on, wherever it is on.** Recipes and
  Discover draw the pills row under the header, diet first. Watch has no
  header, so its filter glyph fills instead — a full-screen video feed has
  room for nothing else.
- **An empty screen says which filter emptied it, and offers to clear it.**
  All three tabs: "Nothing in your library matches Vegetarian diet and
  Japanese." with a Clear filters button. This is the case the persistence
  creates — a diet from a previous launch is otherwise invisible, and
  "No recipes found" would read as lost recipes.

## The shape of it

- **`RecipeFilter` (LadleCore)** is the state: a diet set, a cuisine set, a
  keyword set and an ordered list of ingredient terms. It also carries the
  combination rule, which is the backend's: every diet must hold, any
  cuisine, any keyword, every ingredient term. `apply(to:)` is the library's
  local answer.
- **`RecipeFilterStore` (Ladle/Library)** owns one `RecipeFilter` and
  persists the diet. `LibraryViewModel` holds it, because that is the object
  every tab already has a reference to; `LibraryView` hands the same instance
  to `DiscoverView` and `WatchView`.
- **Recipes** filters in `LibraryViewModel.visibleRecipes`, after the
  existing `RecipeQuery` and before the collection. Never a request.
- **Discover and Watch** mirror the store into `DiscoverViewModel.filter`,
  which behaves exactly like `sort`: a change is a new first page, not a
  thinning of the page on screen. `RemoteDiscoverService` encodes it as
  repeated `diet`, `cuisine`, `keyword` and `ingredient` parameters, in
  vocabulary order, on **every** fetch — the first page, `loadMore`, the
  quiet refresh behind the "New recipes" pill, the page re-recorded when the
  pill is taken, and both rails.
- **Watch's "My Recipes"** feed is the library, so `watchRecipes` applies the
  filter locally too. Otherwise one of the three tabs would ignore the
  shared state.

## Decisions

- **The tri-state on the wire is honoured by sending null.** `RemoteRecipeDTO`
  carries the four families as `RemoteTagListDTO?`. A missing key decodes as
  empty; an explicit `null` decodes as empty; and a write always sends
  `null`, because nothing in the app edits tags and the server reads `null`
  as "leave what is stored". The wrapper exists for exactly this: a nil
  optional property is *omitted* by the synthesized encoder, and the brief
  asks for a literal null. `writingARecipeSendsNullForEveryTagFamily` asserts
  the four keys are `NSNull` in the encoded payload.
- **Tags decode leniently, everywhere.** An unknown member is dropped and the
  recipe is kept. The curated keyword list is expected to grow; a shipped
  build meeting a promoted keyword must lose the keyword, not the recipe —
  and a response from a server that predates tags must still load a library.
  The same rule applies to `Recipe`'s own decoder, which is what the stored
  SwiftData blob runs on upgrade.
- **`RecipeDraft` carries the tags through an edit.** The editor rebuilds a
  `Recipe` from a draft, so without this a rename would strip the local copy
  of its tags until the next sync pull. The server is protected by the null;
  the phone is protected here.
- **The menu, extended, not a sheet.** #63 deliberately replaced a filter
  sheet with a menu. Diet, cuisine and keyword are all multi-select, which a
  menu does with toggles; the only thing a menu cannot host is a text field,
  and that is one alert.
- **The Collections card ignores the diet, and counts through it.** It
  hides itself while a filter is on, which was right when every filter died
  with the session. A diet survives launches, so choosing one would have
  taken "Ready in 30 minutes", "Favorited" and "Haven't cooked yet" away for
  good. It now hides on the *browsing* filters only — and every list the
  Recipes tab draws reads the shared filter, not just the main grid, or a
  row would promise three recipes and open on two.
- **"Clear filters" clears the diet too.** The persistence is there so a diet
  survives *neglect*, not so it survives being cleared. Opening a collection
  is the other way round: `showCollection` drops the browsing filters and
  keeps the diet, because a cook should not re-choose their diet for every
  collection they open.
- **Discover's sort menu gave up the filter glyph.** It was drawing
  `line.3.horizontal.decrease` for a *sort*; with a real filter control
  beside it, two identical icons would have said the two buttons did the same
  thing. Sort now uses `arrow.up.arrow.down`, matching Recipes. Its
  `discover.sort` identifier is unchanged.
- **The demo feed answers the filter.** `DemoDiscoverService` applies
  `RecipeFilter.matches` the way the server applies its query, and
  `PreviewFixtures` tags its six dishes — four vegetarian. Without that, a UI
  run would exercise a control that changes nothing.

## `-reset-library-preferences`

The persisted diet lives under **`ladle.filter.diets`**, comma-separated raw
values in the app's own preference domain.
`RecipeFilterStore.resetPreferences(in:)` **writes the empty value** rather
than removing the key, for the reason
[2026-09-07-reset-preferences-accent.md](2026-09-07-reset-preferences-accent.md)
gives for the accent: a value seeded with `simctl spawn defaults write` lands
in the simulator's device-level domain, which the app reads through but
cannot delete from, so only a write in its own domain clears it.
`LibraryViewModel.resetPreferences` calls it.

That fix ([#106](https://github.com/chetangoel01/recipe-app/pull/106)) is not
in this branch's base, so `resetPreferences` here still removes the other
five keys and only the diet is written. When #106 lands, the diet line joins
the block of writes; it is deliberately one added call at the end of the
function so the conflict surface is a single line.

`testProfileHeaderShowsTheSignedInCook` gained the reset flag. It was the one
UI launch without it, and a filter that now persists would have been handed
to it by whichever run went before.

Watch's filter button is `library.watch.filter`, not `watch.filter`: a page's
action button is `watch.<slug>`, and the UI test that walks the feed finds a
page by that prefix — a control in the same namespace was the first thing it
found.

## Verification

`swift test --package-path Packages/LadleCore`:

```
Test run with 69 tests in 11 suites passed after 0.130 seconds.
```

New there: `RecipeFilterTests` (7 cases — the combination rule, the term
limits, and that clearing the browsing filters leaves the diet), the four tag
cases in `RemoteContractTests`, and `storedRecipesLoadAcrossAVocabularyChange`
in `RecipeModelTests`.

`xcodebuild test -scheme LadleAllTests` on `Ladle-Verify` (iPhone 17,
iOS 26.5). Unit bundle:

```
Test Suite 'All tests' passed at 2026-09-07 16:27:37.216.
     Executed 473 tests, with 1 test skipped and 0 failures (0 unexpected)
```

New there: `RecipeFilterStoreTests` (5), `DiscoverFilterRequestTests` (2 —
the repeated parameters, and that an empty filter adds nothing to the
request), `testTheFilterRidesOnEveryFetchIncludingTheShelvesAndTheNextPage`,
`testChangingTheFilterStartsANewFirstPage` and
`testTheDemoFeedAnswersTheFilterTheWayTheServerWould` in
`DiscoverViewModelTests`, and `testTheSharedTagFilterNarrowsTheLibraryLocally`
and `testOpeningACollectionKeepsTheDietAndDropsTheBrowsingFilters` in
`LibraryViewModelTests`.

`LadleUITests` ran in slices — this machine is shared and a long run kept
being killed part-way — and every case in the bundle passed:

```
RecipesFilterMenuUITests                             4 passed (108.806s)
DiscoverInteractionUITests + testFilteringByTime...  8 passed
StateScenarioUITests + ProfileSheetUITests          20 passed
```

Three of those are new.

- `testADietChosenOnRecipesIsAlreadyAppliedOnDiscover` chooses Vegetarian on
  Recipes, watches the library go from six recipes to four, crosses to
  Discover and finds the same pill and a feed without the meat dish.
- `testAnIngredientTermIsTypedIntoTheControlAndNarrowsDiscover` drives the
  alert from Discover's **toolbar**, types "gochujang", and watches the feed
  come back with one source.
- `testTheControlAndItsAlertAlsoWorkFromWatchsOverlay` drives the same alert
  from Watch's **overlay**, which is a different presentation context and
  the one path nothing else covers, then clears the filter from the empty
  state it produced.

The alert is the only part of the control no unit test can reach, which is
why both placements are driven rather than one.

The whitespace check is clean on every commit.

## Known gaps

- **Tags are not shown on a recipe.** `keywordProposals` decodes, is carried
  through an edit and is never filterable — but nothing draws it yet. The
  Discover shelves built from keywords are the separate issue that #87 blocks.
- **`DiscoverRecipeDTO` carries no tags**, by #105's design, so a Discover
  card cannot show why it matched. Only the detail does.
- **The filter is not part of a Discover deep link or a shared URL.** Nothing
  outside the app can set it.
