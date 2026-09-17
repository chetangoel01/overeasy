# Calories from protein, carbohydrates and fat on the nutrition sheet

Date: September 17, 2026

Issue [#144](https://github.com/chetangoel01/overeasy/issues/144). Branch
`codex/feedback-144-macro-calories`, stacked on
`codex/feedback-resolution-2026-09-17`.

## Purpose

The feedback was "maybe add a breakdown of the calories too in the nutrition
per serving view." The sheet printed a calorie total and three gram counts and
never said how one related to the other.

## Decision

The issue left the form of the breakdown open: by ingredient, by macro, or
both. On September 17 the owner chose **macros** — calories from protein,
carbohydrate and fat, computed in the app from figures it already holds, at
the usual 4, 4 and 9 kcal a gram. There is no backend or contract change.

**Calories by ingredient is deferred.** The shared nutrition model carries
aggregate values only, so an ingredient list needs the pipeline to send
per-ingredient contributions first.

## What the cook sees

Everything is per serving, like the rest of the sheet, and follows the seeded
smash burger through: 38 g, 35 g and 42 g come to 152, 140 and 378 kcal.

- **Hero.** Under the total and its "Calories" caption sit a small "Calories
  from" label and one 12-point bar in three segments — protein, carbohydrates,
  fat — with 4-point gaps and rounded ends.
- **Tiles are the legend.** A segment wears its tile's dot colour, in the
  tiles' order, and each tile gains one line under its name:
  "152 kcal · 23%". Past the default text size, while the tiles still sit
  three across, that line breaks at the dot into "152 kcal" over "23%"
  instead of shrinking; at accessibility sizes the tiles stack and it is one
  line again.
- **One quiet line under the tiles:** "Protein and carbs count 4 kcal a gram,
  fat 9." When the macro sum and the stated calories print as different whole
  numbers it adds "That accounts for 670 of the 680 calories."
- **Percentages** are shares of the macro sum, rounded by largest remainder so
  the three always add to 100 — 1 g of each is 24, 23 and 53, where rounding
  one at a time prints 101.
- **Missing data.** With any macro missing, or no usable serving basis, there
  is no bar, no kcal line and no note, and the tiles keep "Unavailable". With
  the macros but no calories, the bar and kcal lines stay and the comparison
  is dropped. A macro that is truly 0 g prints "0 kcal · 0%" and draws no
  segment. Nothing unavailable is drawn as zero.
- **VoiceOver.** A tile reads "Protein, 38 g, 152 calories, 23 percent". The
  bar and its label are hidden, because the tiles carry the same numbers, and
  the note is spoken with "calories" for "kcal".
- The new figures take no "≈": the
  [marker rides on calories alone](2026-09-07-approximate-nutrition-marker.md).
  The note adds no estimate or warning wording, so it does not pull against
  the quieter estimate notes asked for in #145.

## Decisions

1. **The two numbers are never reconciled.** Fibre, alcohol and a label's own
   rounding all keep 4, 4 and 9 away from a stated total, and the app cannot
   tell which. The note states both figures, names no reason, and moves
   neither. It compares the *printed* whole numbers, so 669.6 beside 670 is
   never explained as "670 of the 670".
2. **A sum above the total has its own sentence**, because "214 of the 210"
   reads as a mistake: "That comes to 214, more than the 210 calories." The
   brief only worded the shortfall, so this wording is a proposal for the
   owner. The seeded miso cookies are the case: 12 + 112 + 90 = 214 beside 210.
3. **The bar is drawn from the printed percentages**, not the raw kcal, so the
   picture and the numbers cannot disagree and the widths fill the bar
   exactly.
4. **Colours are the dots' colours** and are declared once, in `MacroColor`,
   so a dot and its segment cannot drift apart: protein `Intent.success`,
   carbohydrates `Label.secondary`, fat `Label.primary`.
5. **The kcal line is `metadata` in `Label.primary`**, against the general
   pairing of `metadata` with `Label.secondary`, because it is a value rather
   than supporting text. DESIGN.md records the exception.
6. **A negative gram count is treated as unavailable.** The editor will parse
   one, and it is bad data rather than a share of anything.

## Affected components

- `Packages/LadleCore/Sources/LadleCore/Nutrition.swift` — `MacroCalories`
  and `Nutrition.macroCalories`, nil unless all three macros are known,
  non-negative and add up to something.
- `Ladle/Nutrition/NutritionNote.swift` — `macroCalories(_:of:)`, the line
  under the tiles.
- `Ladle/Nutrition/NutritionView.swift` — the bar, the tile line, the note and
  `MacroColor`. The view reads `displayedNutrition`, which is already empty
  when the serving basis is unusable, so that case needs no gate of its own.
- `DESIGN.md` gains a Nutrition section.

No file was added or removed, so there is no project change.

## Tests

- `NutritionTests.swift`, suite "Macro calories": the 4/4/9 sums, shares that
  add to 100 on a split that naive rounding gets wrong, nil with a macro
  missing, and nil for a zero total or a negative gram count. Red first as a
  missing member.
- `NutritionNoteTests.testTheMacroNoteCitesTheTotalOnlyWhenTheWholeNumbersDisagree`.
  Red first against a helper that always compared: it printed "510 of the 510
  calories" and "of the" for a sum above the total.
- No hosted-view test. The view's gate is one optional, and the cases that
  make it nil are covered where it is computed.

## Verification

Xcode 27.0, on a private iPhone 17 Pro simulator (iOS 26.5) created for this
work and deleted afterwards.

```
swift test --package-path Packages/LadleCore
  Test run with 95 tests in 12 suites passed            (91 before)

xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -only-testing:LadleTests
  Test Suite 'All tests' passed
  Executed 591 tests, with 1 test skipped and 0 failures (590 before)

  -only-testing:LadleUITests/HIGRegressionUITests/testHealthExportReturnsToNutritionWithinTheSheet
  Executed 1 test, with 0 failures
```

The skip is the live App Attest test, as before. That UI test opens this sheet
and scrolls to the export button, which now sits lower. `git diff --check` is
clean.

The captures below come from the seeded library through the same route:
recipe, Recipe options, View nutrition. The states the seeded library cannot
reach were rendered once through a
temporary hosted view that is not committed: a missing macro, no calories, an
unusable serving basis, a sum above the total, a true zero in dark, and
four-digit kcal at the default, extra-large and largest standard sizes.

| | Before | After |
| --- | --- | --- |
| Light | ![Before, light](captures/2026-09-17-macro-calories/before-light.png) | ![After, light](captures/2026-09-17-macro-calories/after-light.png) |
| Dark | ![Before, dark](captures/2026-09-17-macro-calories/before-dark.png) | ![After, dark](captures/2026-09-17-macro-calories/after-dark.png) |

Largest accessibility text size:

| Hero and first tile | Tiles and note |
| --- | --- |
| ![AX5 hero](captures/2026-09-17-macro-calories/after-ax5-hero.png) | ![AX5 tiles](captures/2026-09-17-macro-calories/after-ax5-tiles.png) |

## Known rough edges

- **Protein is faint in dark mode.** `Intent.success` resolves to `#294233`
  there, about 1.3:1 against the steel hero and 1.5:1 against a raised tile.
  The dot had the same weakness before this change; a segment a quarter of
  the bar wide makes it easier to see. The colours were the owner's choice, so
  they are unchanged. A fix is a lighter dark value for a mark, which is a
  theme decision, and `MacroColor.protein` is the one line that would read it.
- At the largest standard size "Carbohydrates" still shrinks to fit its tile,
  which leaves that tile a couple of points shorter than its neighbours. That
  predates this change.
