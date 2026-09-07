# Cook for a different number of people

Date: September 7, 2026
Issue: [#100](https://github.com/chetangoel01/recipe-app/issues/100)
Stacked on: [#103](https://github.com/chetangoel01/recipe-app/pull/103) (issue #90)
Status: **built, unit- and UI-tested on the review simulator.**

## Purpose

A TestFlight tester asked to "edit the recipe size". The servings field in the
editor already existed; what did not is **scaling**. Changing that number moved
the nutrition — `Nutrition.perServing` divides by the serving basis — and left
every ingredient exactly as imported, so the recipe became internally
inconsistent rather than resized.

The decisions on the issue (2026-09-07) settled the reading: a cook-time
multiplier, held in view state, that nothing writes and nothing syncs.

## What the cook sees

- **The yield is the control.** The right-hand half of the metadata band — the
  "4 servings" a cook is looking at when they think "I need six" — is a button,
  marked with the same `chevron.up.chevron.down` iOS uses for an adjustable
  value. It opens a sheet with a servings stepper, ranged 1 to
  `RecipeContractLimits.maximumServings`, whose arrows disable themselves at
  each end.
- **A scaled band says so.** The value becomes the chosen count and the label
  under it becomes "Scaled from 4 servings", so the band never claims the
  recipe yields something it does not.
- **Scaled rows are recomputed**, `normalizedQuantity × chosen ÷ stored`,
  rendered through `Ingredient.measuredAmount(_:)` — the seam #90 left for
  this. "1 lb ground beef" at eight servings reads "2 lb ground beef".
- **Rows the creator never quantified stay as written** and carry a quiet
  "Not scaled" marker, on the same origin as the uncertainty note the list
  already shows.
- **Cook mode cooks the scaled amounts**, and says "Scaled to 8 servings"
  under the title, because the control is not on that screen.
- **Closing the recipe is the undo.** There is no save, no confirmation, and
  nothing in the sheet writes to the recipe.
- **Nutrition does not move.** It is already stated per serving, which is true
  at any count.

## Decisions

- **State lives in `RecipeDetailView`, not in a detail view model — there is
  no such object.** The issue assumed one and assumed Cook mode shared it.
  In fact `RecipeDetailView` holds `@State`, and `CookingViewModel` is a
  separate object constructed at "Start Cooking" from `displayedRecipe`. So
  the multiplier reaches Cook mode by being passed at construction:
  `CookingViewModel(recipe:scaling:)`, stored as a `let`, read by
  `FullRecipeView` through `viewModel.multiplier`. It is a snapshot rather
  than a shared object because the control is not on the cooking screen and
  the page underneath is covered while it is open. `WatchView`, which also
  starts a session, passes nothing and cooks the recipe as written.
- **`multiplier` is `nil` until a cook picks a different number**, rather than
  defaulting to 1. The unscaled rule is #90's — the creator's verbatim phrase
  wins — and an unscaled page has to be byte-identical to what it renders
  today. Absence of a factor is what every row reads as "print it verbatim",
  so there is no arithmetic path through the default case at all.
- **Plain decimals, two places, no unit cleverness.** Twice 1½ tsp is "3 tsp",
  not "1 tbsp". A third of a cup is "0.33 cup". Converting units is a second
  feature with its own failure modes, and the issue explicitly started here.
- **The band's "Scaled from" phrase is built from the number, not from
  `ladleYieldText`.** That property hedges an uncertain yield with "About" and
  replaces a lone serving with "Yield unknown", and "Scaled from Yield
  unknown" is not a sentence. `RecipeScaling.baseYieldText` says "4 servings"
  plainly. The control is still offered on a recipe whose yield is flagged
  uncertain: the stored number is the basis the rest of the app already
  divides nutrition by, so scaling from it is no more of a guess than the
  nutrition panel already is.
- **`servings <= 0` withholds the control** rather than showing one that
  cannot mean anything — the ratio would divide by zero. The band falls back
  to the read-only yield it renders today.
- **The "Not scaled" marker is quieter than the uncertainty note beside it.**
  Both are a `Label` with `exclamationmark.circle` on the row's origin, but
  the marker uses `Label.secondary` where uncertainty uses the accent. An
  unquantified line is an aside about one row, not a warning about the recipe,
  and a scaled list of eight ingredients could otherwise light up in accent.
- **The scaled state is announced once, when the sheet closes.** The stepper
  reads its own value on every press, so announcing from the band on each
  change made a cook stepping four to eight hear each count twice. The
  announcement fires on dismissal, and only if the count actually moved. The
  band also carries an accessibility label, value and hint, so a VoiceOver
  user who missed the announcement can read the state off the control.
- **An edit re-bases the scaling.** `applyChangedRecipe` rebuilds it from the
  recipe's new `servings`, because a ratio against a yield the recipe no
  longer claims is meaningless.
- **The reimport sheet's band stays read-only.** It draws the same component
  over a candidate the cook is comparing, not cooking from, so it passes no
  binding and its yield is the plain fact it is today.
- **The demo data now carries the split.** #90 left `normalizedQuantity` unset
  and said so: "the '½' rows make a half-hearted job of it, and #100 is the
  change that needs it". Both writers — `PreviewFixtures` and
  `DemoImportService` — derive it from the amount column their tables already
  had, through one shared `demoNormalizedQuantity`, which reads "1½" the way
  the importer does. Nothing on screen moves, because `quantityText` still
  wins for an unscaled row; what changes is that a demo recipe can be scaled,
  where before every row would have read "Not scaled".

### Left alone, on purpose

- **Nutrition.** `RecipeNutritionSummary` and `NutritionView` are both headed
  "per serving" and show no recipe total, so there is nothing on the page for a
  multiplier to change. The issue's rule — a total would become
  `perServing × chosen` — has no call site to apply to yet.
- **Focus mode** lists the ingredient *names* for the current step and no
  amounts, so it has nothing to scale.
- **The editor.** Its Servings field keeps its meaning: the yield the recipe
  claims. Scaling never writes to it.
- **Timers and method text** are not scaled. Doubling a batch does not double a
  bake, and no step's prose is rewritten.

## Affected files

- `Ladle/RecipeDetail/RecipeScaling.swift` — new. The value: base, chosen,
  availability, clamped range, multiplier, yield phrases.
- `Ladle/Design/RecipePresentation.swift` —
  `Ingredient.cookingDetailText(scaledBy:)` and `isScalable`; the existing
  property delegates with `nil`.
- `Ladle/RecipeDetail/RecipeMetadataBand.swift` — the tappable yield, the
  scaled labels, the VoiceOver announcement, and the private `ServingsSheet`.
- `Ladle/RecipeDetail/IngredientList.swift` — `scaledBy` and the "Not scaled"
  marker.
- `Ladle/RecipeDetail/RecipeDetailView.swift` — the `@State`, re-based on an
  edit, passed to the band, the list and the cooking session.
- `Ladle/Cooking/CookingViewModel.swift` — `scaling`, `multiplier`,
  `scaledYieldText`.
- `Ladle/Cooking/FullRecipeView.swift` — scaled checklist rows, the marker, and
  the line under the title.
- `Ladle/Data/PreviewFixtures.swift`, `Ladle/Import/DemoImportService.swift` —
  demo rows carry `normalizedQuantity`.
- Tests: `LadleTests/RecipeScalingTests.swift` (new),
  `LadleTests/IngredientRowTextTests.swift` (scaled rows),
  `LadleTests/CookingViewModelTests.swift` (the snapshot),
  `LadleUITests/RecipeScalingUITests.swift` (new).

## Verification

Run on the `Ladle-Verify` simulator (`576EB306-…`, iPhone 17, iOS 26.5) with a
private `-derivedDataPath`. The usual iPhone 17 Pro was running another agent's
`LadleAllTests` for the length of this task; a first attempt there sat for
fifteen minutes without starting a test and was killed.

- **Red, before the behaviour existed.** `RecipeScaling` and
  `cookingDetailText(scaledBy:)` were written as shells first — the type and
  the method existed, with the *unscaled* behaviour — so the red is
  assertions rather than a compile break:
  `-only-testing:LadleTests/RecipeScalingTests
  -only-testing:LadleTests/IngredientRowTextTests` — "Executed 23 tests, with
  11 failures (0 unexpected)", including `("1 lb ground beef — 80/20, in four
  loose balls") is not equal to ("2 lb ground beef — …")` and `("nil") is not
  equal to ("Optional(1.5)")`.
- **Green, after:** the same command — "Executed 23 tests, with 0 failures (0
  unexpected)", "** TEST SUCCEEDED **".
- **Whole unit suite,** `-only-testing:LadleTests` — "Executed 493 tests, with
  1 test skipped and 0 failures (0 unexpected)", after rebasing onto #103's
  later editor commit. This is the run that checks the fixture change did not
  move any rendered string: #90's `testTheDemoLibraryReadsWithItsUnits` still
  passes unchanged, as do that commit's editor tests, which now write a
  `normalizedQuantity` of their own for scaling to multiply.
- **Whole UI suite,** `-only-testing:LadleUITests` — "Executed 29 tests, with 0
  failures (0 unexpected)", "** TEST SUCCEEDED **". Worth running rather than
  reasoning about: `StateScenarioUITests` drives card → detail → Start Cooking
  → Focus mode, which is the flow this change rebuilt.
- **UI test,** `-only-testing:LadleUITests/RecipeScalingUITests` — taps the
  yield on the seeded demo library, steps 4 → 8, and asserts the ground-beef
  row moves from "1 lb" to "2 lb", that the verbatim row is gone, and that the
  band reads "Scaled from 4 servings" — "Executed 1 test, with 0 failures (0
  unexpected) in 22.243 seconds", "** TEST SUCCEEDED **". It attaches two
  screenshots, the stepper at eight and the scaled page.
- **Build,** `xcodebuild build -scheme Ladle` — "** BUILD SUCCEEDED **", so the
  app and the Share Extension both compile.
- **Looked at**, not only asserted: the two attachments show the band reading
  "8 servings ⌃⌄ / Scaled from 4 servings" in the same shape as "25 min /
  Total time" beside it, and the sheet as a plain iOS stepper card.

### Two things this machine did, that the next agent should not chase

- **A stale `-derivedDataPath` produced a false failure.** `RecipeScalingUITests`
  failed on "no `recipe.yield` button", and the captured hierarchy showed the
  old read-only band. `strings` on the built `Ladle.app` had no "Scaled from"
  in it: the app had not been rebuilt, after earlier runs in the same
  DerivedData were killed part-way. Deleting the directory and rebuilding from
  clean fixed it. Check the binary before believing a UI failure that says a
  view is missing.
- **`DiscoverInteractionUITests.testDiscoverRecipeSupportsTapAndLongPress`
  failed twice inside a whole-suite run** with "Restarting after unexpected
  exit, crash, or test timeout", at two different points, and no crash report
  on the device. Run alone on this branch it passes in 17s, as it does on the
  base commit; the whole suite then passed 29/29. Several agents had
  simulators booted at the time. Environment, not this change.

### Gap

**The "Not scaled" marker has no on-screen coverage.** Every row in the demo
library now has a `normalizedQuantity`, because every demo row was written
with an amount, so nothing in the seeded data can render it. The rule behind
it is unit-tested (`testARowWithoutASplitIsUntouchedByScaling`), and the marker
is four lines of view code in two places, but no test draws it. Giving one
demo row a genuinely unquantified amount — "kosher salt, to taste", which is a
shape the backend certainly sends and the demo library does not have — would
fix that and make the demo library more honest. It changes demo recipe content,
which this issue did not ask for, so it is left for a follow-up.

**Large type was reasoned about, not seen.** Two attempts to capture the scaled
page at `UICTContentSizeCategoryXXL` were killed by this machine before they
rendered anything. What shipped is the conservative shape — the band's label
keeps its original no-line-limit behaviour, so "Scaled from 4 servings" wraps
inside a half-width tile rather than truncating — but no screenshot proves it.
The same is unchecked for `ServingsSheet`, a `VStack` at `.medium` with no
`.large` detent and no scroll view: at accessibility sizes the reset button may
sit below the detent. Adding `.large` as a second detent is the likely fix and
needs one more `RecipeScalingUITests` run, because the Done path is what that
test drives.
