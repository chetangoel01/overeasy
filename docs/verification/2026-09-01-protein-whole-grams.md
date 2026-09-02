# Protein rounds to whole grams on cards

Date: September 1, 2026
Issue: [#34](https://github.com/chetangoel01/recipe-app/issues/34)
Triage: [2026-08-31 UI feedback](../plans/2026-08-31-ui-feedback-triage.md) § 16
Status: **built and verified by unit test.**

## Purpose

A recipe card read `569 cal · 24.5g protein`: one number rounded, the next
carried to a tenth, from the same estimate. The numbers come from a
normalizer's guess at unquantified amounts and a USDA row matched by search,
and two refreshes of the same recipe differ by a few percent. A tenth of a gram
claims a precision the pipeline does not have, and `24.5` reads as *measured*
in a way that `25` does not. The simulator's fixtures are whole grams, which is
why this only shows against real data.

## What changed

Two lines in `Ladle/Design/RecipePresentation.swift`.

**1. The card's protein is a whole gram.** `libraryFacts` now passes the same
`maximumFractionDigits: 0` to the protein branch that the calories branch has
always had. That is the change the issue asked for.

**2. Halves round away from zero, not to even.** Passing
`maximumFractionDigits: 0` alone was *not* enough to make the issue's own
example come out right. `ladleNumber` formats through Foundation's
`FormatStyle`, whose default is half-to-even, so a card whose per-serving values
land on `568.5` and `24.5` would have read `568 cal · 24g protein` — both
numbers rounded *down* off a half, and the protein moving away from the `25`
the issue expects. `ladleNumber` now asks for
`.rounded(rule: .toNearestOrAwayFromZero)`.

Measured on this machine before choosing (`Decimal`, via `.formatted`):

| Value | Digits | Half-to-even (was) | Away from zero (now) |
|-------|--------|--------------------|----------------------|
| 568.5 | 0 | 568 | **569** |
| 24.5  | 0 | 24  | **25**  |
| 569.5 | 0 | 570 | 570 |
| 24.45 | 1 | 24.4 | **24.5** |
| 24.55 | 1 | 24.6 | 24.6 |

## The decision, and why the rule is not conditional

The rounding rule is applied to `ladleNumber` **unconditionally**, not gated on
`maximumFractionDigits == 0`.

Gating it would have contained nothing. Every existing whole-number caller —
calories on the card, on the metadata band, on the nutrition panel and on the
watch overlay — takes `maximumFractionDigits: 0` and so gets the new rule
either way. The gate would only have bought a four-line formatter two different
tie-break rules depending on its argument, which is the same species of
inconsistency this issue was filed about.

What it costs: at every site that still shows a tenth, a value landing exactly
on a hundredth-half now rounds up rather than to even — `24.45 g` reads `24.5`
where it read `24.4`. **These ties will occur**, and the change is not being
justified as rare: any one-decimal total over an even serving count lands on
one (48.9 g over 2 servings is 24.45), and USDA rows carry a decimal or two.
The justification is the rule itself. Half-to-even exists to keep bias out of a
summed column; every one of these numbers is read once, on its own, by a person
deciding whether to cook something.

## Scope: cards only

Only `libraryFacts` moved from tenths to whole grams. Every other `ladleNumber`
caller that takes the default precision still shows a tenth, deliberately:

| Site | Shows | Why it stays |
|------|-------|--------------|
| `Ladle/Nutrition/NutritionView.swift:198` — `macro(name:value:color:)` | protein, carbs, fat | The detail panel is where someone goes *for* the numbers, and it already carries the "≈" estimated marker the card omits. The issue is about cards. |
| `Ladle/Nutrition/NutritionView.swift:227` — `nutrientRow(_:)` | sodium, fibre, sugar and the rest | Same panel, same argument. A tenth of a gram of fibre is the same overstated precision, and it should be decided for the panel as a whole rather than one row at a time. |
| `Ladle/RecipeDetail/RecipeMetadataBand.swift:181` — `grams(_:)` | protein, carbs, fat | Same screen. The band formats through its own helper, so it did not follow the card by accident; checked, and left. |
| `Ladle/RecipeDetail/RecipeMetadataBand.swift:192` — `ladleYieldText` | servings | Not nutrition. The editor accepts fractional servings, so the tenth is carrying real information here — "1.5 servings" is a yield someone typed, not an estimate. |
| `Ladle/Library/WatchView.swift:687` | protein | Not raised in the issue or the brief. It is the video-feed overlay, not a library card, and composes its own string with an "≈" prefix and the yield. Flagged so the inconsistency is a choice rather than an oversight. |
| `Ladle/Health/HealthExportSheet.swift:301` — `decimalText(_:)` | exported metrics (`:292`) and servings (`:287`) | A confirmation sheet for values about to be written to Apple Health. What gets exported is a different decision from what gets scanned. |

All of them now round halves away from zero rather than to even, since they
share `ladleNumber`. `ladleYieldText` is the one to look at first if that
proves unwelcome: "About 2.25 servings" now reads `2.3` where it read `2.2`.

## Files

| File | Change |
|------|--------|
| `Ladle/Design/RecipePresentation.swift` | `maximumFractionDigits: 0` on the protein branch; `.rounded(rule: .toNearestOrAwayFromZero)` in `ladleNumber` |
| `LadleTests/LibraryViewModelTests.swift` | `testDenseArchiveFactsRoundHalvesAwayFromZero` — new |

## Verification

The new test uses a fixture whose per-serving values land exactly on a half on
**both** branches — 1137 calories and 49 g of protein over a serving basis of 2
— so it pins the rounding rule and not just the digit count. It fails three
different ways, which is the point:

- before the change: `568 cal · 24.5g protein` (the tenth)
- with `maximumFractionDigits: 0` alone: `568 cal · 24g protein` (the default
  rule, rounding the issue's example the wrong way)
- after both changes: `569 cal · 25g protein`

Chosen over the obvious `1139 / 2` because `569.5` rounds to `570` under *both*
rules — that fixture would have asserted nothing about the calories branch.

Red first, on the new test alone:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests/LibraryViewModelTests/testDenseArchiveFactsRoundHalvesAwayFromZero
```

> `XCTAssertEqual failed: ("568 cal · 24.5g protein") is not equal to ("569 cal · 25g protein")`
> `Executed 1 test, with 1 failure (0 unexpected)`

Then green, whole suite:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LadleTests
```

> `Executed 363 tests, with 1 test skipped and 0 failures (0 unexpected) in 3.637 (3.760) seconds`
> `** TEST SUCCEEDED **`

363, one more than the 362 the previous change recorded — the new test, and
nothing else moved.

The five existing `libraryFacts` assertions are unchanged and still pass,
including `testDenseArchiveFactsRoundRepeatingPerServingValues`, whose
`625 / 11` and `55 / 11` format identically under either rule.

No `xcodegen generate` run: no source file was added or removed.
