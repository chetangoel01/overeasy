# Stop an ingredient row saying its unit twice

Date: September 7, 2026
Issue: [#90](https://github.com/chetangoel01/recipe-app/issues/90)
Status: **built, unit-tested and building clean on the review simulator.**

## Purpose

A TestFlight tester reported "repetitive units in the recipe ingredients" and
sent a screenshot of a row reading "100 g g flour".

The parser is not at fault. The extraction prompt defines the two fields as
different things (`Backend/ladle/extraction/prompt.py:42-50`):
`quantityText` is what the creator said, verbatim — "2 16oz cans", "100 g" —
and `normalizedQuantity` with `unit` is the machine-readable split of that
same phrase. "100 g" beside `unit = "g"` is correct data. The duplication was
`Ingredient.cookingDetailText`, which joined `quantityText`, `unit` and the
name with spaces and so printed the unit once from each field. Client-only
fix; no backend change and no backfill.

## What the cook sees

One rule, in one formatter, everywhere a row renders — the ingredient list on
a recipe, the checklist in Cook mode:

- **A creator's own words, whole, with no unit stapled to them.** "100 g
  flour", not "100 g g flour". Where the creator said "2 16oz cans", that is
  what the row says.
- **A row with no verbatim text falls back to the split**: "2 cups flour".
  This is the only unscaled case in which `unit` is printed at all.
- **A counted thing keeps its number**: "4 potato rolls", where the split has
  an amount and no unit.
- **A `unit` with no amount either side of it is dropped.** "flour", not
  "cups flour" — a bare unit is not an amount, and a row that leads with one
  reads as a bug.
- **An unquantified ingredient is just its name**: "flaky salt".
- **The preparation still trails the row**, unchanged: "1 lb ground beef —
  80/20, in four loose balls".

## Decisions

- **The two amount forms have distinct jobs and never combine.** The verbatim
  phrase wins outright when it exists; the split is a fallback, not an
  addition. Agreed on the issue on 2026-09-07.
- **`measuredAmount(_:)` is the seam for scaling (#100).** It takes the
  `Decimal` rather than reading `normalizedQuantity`, so scaling can render
  `normalizedQuantity × factor` through the same formatter without touching
  the callers. No scale factor is threaded through anything yet — that is
  #100's work, and an unused parameter now would be dead code.
- **Two fraction digits for a measured amount**, not the one `ladleNumber`
  defaults to. A tenth of a gram is false precision on a nutrition panel, but
  a quarter cup is an amount somebody measures, and 0.25 rounding to "0.3"
  would be wrong in the kitchen. This barely shows today — the fallback is
  rare — and matters when #100 starts dividing by three.
- **Blank strings read as absent.** The wire contract types every one of these
  fields as an optional string and promises no trimming, so `""` has to mean
  "no value" rather than an extra space in the row.
- **The demo fixtures were carrying the wrong shape and are corrected.**
  `PreviewFixtures` and `DemoImportService` both wrote a bare "1" into
  `quantityText` and "lb" into `unit`, which is not what an import looks like;
  under the new rule those rows would have read "1 ground beef". Both now
  compose the verbatim phrase from the amount and unit columns their tables
  already carry, so the tables themselves did not change and the demo library
  reads exactly as it did before. `normalizedQuantity` is still unset in the
  demo data — the "½" rows make a half-hearted job of it, and #100 is the
  change that needs it.

### Not covered by the issue, and left alone

**The editor can still produce the shape this fix demotes.** `RecipeEditorView`
offers separate "Quantity" and "Unit" fields (lines 689 and 696) and
`RecipeDraft.recipe(updatedAt:)` saves them apart (lines 208-212). A cook who
types "2" and "cups" now gets a row reading "2 flour" — the unit they typed is
stored, and not shown. Whether the editor should offer one field, compose the
verbatim text on save, or something else is a product decision that the issue's
decisions do not settle, so nothing in the editor was touched. Worth its own
issue.

## Affected files

- `Ladle/Design/RecipePresentation.swift` — `Ingredient.measuredAmount(_:)`,
  `Ingredient.amountText`, the rewritten `cookingDetailText`, and a fileprivate
  `String.nonEmpty`.
- `Ladle/Data/PreviewFixtures.swift` — `orderedIngredients` composes the
  verbatim phrase.
- `Ladle/Import/DemoImportService.swift` — the same, for demo imports.
- Tests: `LadleTests/RecipePresentationTests.swift` (new).

## Verification

Run on the `Ladle-Verify` simulator (`576EB306-…`, iPhone 17, iOS 26.5) rather
than the usual iPhone 17 Pro, which was busy with another agent's test run for
the length of this task. These are unit tests and a build; neither depends on
the device model.

- Red, before the fix:
  `xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests -destination
  'platform=iOS Simulator,id=576EB306-ACFA-45EB-A1FF-54044EE1D9EA'
  -only-testing:LadleTests/IngredientRowTextTests` — "Executed 8 tests, with 6
  failures (0 unexpected)", including `("100 g g flour") is not equal to
  ("100 g flour")`, the tester's screenshot in one line.
- Green, after: the same command — "Executed 8 tests, with 0 failures (0
  unexpected)", "** TEST SUCCEEDED **".
- Whole unit suite, `-only-testing:LadleTests` — "Executed 469 tests, with 1
  test skipped and 0 failures (0 unexpected)". This is the run that checks the
  fixture change; no test asserted a demo row's quantity text before, and one
  does now.
- `xcodebuild build -project Ladle.xcodeproj -scheme Ladle` — "** BUILD
  SUCCEEDED **", so the app and the Share Extension both compile.

No simulator capture. The screenshot in the report is of an anonymous
tester's recipe that cannot be reproduced, and the demo library's rows are
pinned instead by `testTheDemoLibraryReadsWithItsUnits`, which asserts the
first two rows of the smash burgers read "1 lb ground beef — 80/20, in four
loose balls" and "4 potato rolls — split". That assertion is durable in a way a
screenshot is not.
