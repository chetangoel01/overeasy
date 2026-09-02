# Show the cooking time a recipe actually has

Date: September 2, 2026
Issue: [#64](https://github.com/chetangoel01/recipe-app/issues/64)
Status: **built and verified on the review simulator.**

## Purpose

Most recipes opened with "— Total time". Not a rendering bug in the usual
sense: of the 28 recipes in the live library, 6 carry `total_minutes` and 8
carry `cooking_minutes`, and the band read `totalMinutes` alone. A creator
who said how long the dish cooks had told the cook something useful, and the
app threw it away — then compounded it, because the "30 min or less" filter,
the time sort, the "Ready in 30 minutes" collection and the Discover "Quick
dinners" shelf all read the same single field, so a 20-minute cook-only
recipe was neither shown nor findable.

This is the iOS half of #64. The other half — asking the model for a
conservative total when the creator states none — lands separately on the
backend. It reaches the app with no wire change: the estimate travels as a
`FieldUncertainty` with `field == "total_minutes"`, the shape the recipe
already carries, so the rendering built here is ready for it.

## What the cook sees

- **The band shows whichever time the recipe states**, under a label that is
  true of it: the stated total, or prep + cook when both are stated, both
  under "Total time"; otherwise cook alone under "Cook time" or prep alone
  under "Prep time". A recipe that states no time at all still shows "—"
  under "Total time".
- **An estimated total says "About 45 min"** — the rule "About 4 servings"
  already uses for an estimated yield.
- **The reason sits under the band as one line**, in the same font and accent
  colour as the notes on an uncertain ingredient or step, so the cook can see
  the number came from the method rather than the creator.
- **Time filters and sorts follow the same rule.** A cook-only 20-minute
  recipe now passes "30 min or less", sorts into its right place by time and
  appears under "Ready in 30 minutes". Discover's "Quick dinners" shelf reads
  it too in demo builds; the live shelf is the server's query, which the
  backend half of #64 widens the same way.

## Decisions

- **One derivation, in LadleCore.** `Recipe.displayedTime` returns
  `(minutes, label)` and `Recipe.isTimeEstimated` reports the
  `total_minutes` uncertainty. The band, the query filter, the query sort,
  the library's Quick collection and the Discover demo shelf all read it, so
  they cannot drift apart. The rule matches what the server does for the
  "Quick dinners" query and what the editor already did for its draft.
- **The editor's derivation stays as it is.** `RecipeDraft.recipe(updatedAt:)`
  writes a real `totalMinutes` from prep + cook, because a cook who types
  both has stated a total. `displayedTime` derives for display only; it never
  writes back.
- **"About", not a badge.** PRODUCT.md's "Honesty in data" asks that every
  estimate be labeled inline. Yield already does that in this exact band, and
  a second visual language for the same idea two inches apart would be worse
  than none.
- **An estimate never blocks.** The note is rendered only when there is a
  number for it to explain, and carries no review affordance — it says how
  the number was arrived at, not that the recipe needs checking.
- **The demo library carries all three shapes.** One-Pot Lemon Orzo states
  only its 35 minutes of cooking, Sheet-Pan Gochujang Chicken carries an
  estimated 45-minute total, and the rest state totals. Nothing was added or
  removed, and every recipe's derived time is what it was, so the counts the
  filter tests pin ("30 min or less" leaves three of six) did not move.
  `largeLibraryRecipes` reads `displayedTime` for the same reason — its
  orzo-templated recipes keep their 35 minutes rather than silently falling
  to the 30-minute default — and `RecipeEditorViewModelTests` follows the
  fixture: the orzo's prep field is now empty, which is the honest thing for
  the editor to show.

## Affected files

- `Packages/LadleCore/Sources/LadleCore/Recipe.swift` — `displayedTime`,
  `isTimeEstimated`.
- `Packages/LadleCore/Sources/LadleCore/RecipeQuery.swift` — the time filter
  and the time sort.
- `Ladle/RecipeDetail/RecipeMetadataBand.swift` — the band's time item,
  `ladleTimeItem`, `ladleTimeNote`, and the note line under the card.
- `Ladle/Library/LibraryViewModel.swift` — the Quick collection.
- `Ladle/Remote/DiscoverService.swift` — the demo Quick dinners filter.
- `Ladle/Data/PreviewFixtures.swift` — `DemoTiming`, the cook-only and
  estimated demo recipes.
- Tests: `Packages/LadleCore/Tests/LadleCoreTests/RecipeTimeTests.swift`,
  `LadleTests/LibraryViewModelTests.swift`,
  `LadleTests/RecipeEditorViewModelTests.swift`.

## Verification

- `swift test --package-path Packages/LadleCore` — "Test run with 54 tests in
  10 suites passed", including the seven-case derivation table in
  `RecipeTimeTests`.
- `xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests
  -destination 'platform=iOS Simulator,id=1CE0C07F-8CDD-41E5-9B38-DD908B5F5CBD'
  -only-testing:LadleTests -only-testing:LadleUITests/RecipesFilterMenuUITests`
  — LadleTests: "Executed 427 tests, with 1 test skipped and 0 failures (0
  unexpected)"; RecipesFilterMenuUITests: "Executed 1 test, with 0 failures
  (0 unexpected)", so the merged filter menu still narrows six recipes to
  three on "30 min or less".
- Captures in `captures/2026-09-02-recipe-time-display/`, taken on the iPhone
  17 review simulator launched with `-ui-testing -onboarding-complete
  -reset-library-preferences`:
  - `before-cook-only.png` — One-Pot Lemon Orzo, which states 35 minutes of
    cooking, showing "—" under "Total time".
  - `after-cook-only.png` — the same recipe showing "35 min · Cook time".
  - `after-estimated.png` — Sheet-Pan Gochujang Chicken showing
    "About 45 min" with its reason under the band.

The before capture was taken with the demo fixture already carrying the
cook-only recipe and the band still reading `totalMinutes` — on the
untouched build every demo recipe stated a total, so there was no way to
photograph the failure the live library actually shows.
