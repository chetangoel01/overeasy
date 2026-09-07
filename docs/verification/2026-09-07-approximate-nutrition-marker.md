# The card says "≈ 410 cal" when the total is missing an ingredient

Date: September 7, 2026

The client half of issue #37's Tier 0. Stacked on
[the backend change that removed the coverage floor](2026-09-07-nutrition-no-coverage-floor.md)
(PR #104), which added `NutritionDTO.approximate: bool` and stopped a missing
spice voiding a recipe's calories.

## Purpose

A recipe is no longer voided for nutrition reasons: whatever matched is
totalled and whatever did not is skipped and recorded. That leaves the app
printing a number that is honest about what it counted and silently short by
what it could not. From the 2026-09-07 decisions on #37: *"The card shows
'≈ 540 cal' whenever anything was skipped or weak. Which ingredients, and
why, lives on the nutrition sheet; the card does not carry a count."*

This teaches the client to carry the marker and put it in front of every
calorie figure it prints.

## Decisions in force

1. **"≈" means incomplete, and only that.** See below — this is the one
   decision that goes beyond the brief.
2. **The marker rides on calories alone**, everywhere. Protein, carbs and fat
   are drawn from the same partial total, but one caveat on a line reads as a
   caveat where four read as noise, and calories are the number people scan
   for.
3. **The card carries the marker and nothing else.** No count, no words.
4. **The sheet's line was already there**, and is not duplicated.
5. **The Health export is never blocked**, only annotated.

### "≈" means incomplete, not estimated

The app already printed "≈" — in three places, for `isEstimated`:
`NutritionView.calorieText`, `HealthExportSheet.metricText` and
`WatchView.metadata`. Every calculated panel is estimated, so that marker sat
on effectively all of them and distinguished nothing.

`approximate` is the narrower and more useful claim, and it cannot share a
glyph with the wider one: a "≈" that means two things on two screens means
neither. So those three sites were **re-pointed**, not added to — the glyph
now answers `approximate` everywhere, and `isEstimated` keeps the words it
already had elsewhere: the "Estimated" pill on the recipe detail band and the
"Nutrition is estimated from the imported recipe." line on the sheet. Nothing
that used to say "estimated" in words stopped saying it.

This is a behaviour change beyond the literal brief, which described only
adding the marker to the card. It is recorded here because it is the reason
the sheet and the Watch feed read differently after this change than before:
a panel that is estimated but complete now shows a bare number where it used
to show "≈".

The companion doc for PR #104 says "Cards keep no marker — DESIGN.md keeps the
estimate marker off cards." That was written before the 2026-09-07 decisions,
which reverse it for `approximate` specifically. The rule as it now stands
lives in the `libraryFacts` doc comment, which is where the grep for it
actually leads — DESIGN.md never mentioned nutrition.

## What changed

### The model (`Packages/LadleCore`)

`Nutrition.approximate: Bool` (default `false`), threaded through
`scaled(toServings:)` — which matters more than it looks, because every figure
the app prints goes through `perServing`, and `scaled` builds a fresh value. A
marker the scale drops is a marker no screen ever sees.

Two decode paths gained a hand-written `init(from:)` so an absent key means
complete:

- `RemoteNutritionDTO` — an older server never sends it.
- `Nutrition` itself — `SwiftDataRecipeRepository` stores each recipe as
  `JSONEncoder().encode(recipe)`, so every recipe already in an installed
  app's local store was encoded before the field existed. Synthesised `Codable`
  would have thrown `keyNotFound` on all of them.

`encode(to:)` stays synthesised in both.

### The helper (`Ladle/Design/RecipePresentation.swift`)

```swift
func ladleApproximate(_ text: String, when approximate: Bool) -> String
extension Nutrition { var ladleCalorieText: String? }
```

`ladleCalorieText` is the whole calorie figure as every surface prints it —
rounded to a whole number, half away from zero, marked when incomplete. The
free function exists for Health export, which holds a `HealthExportPayload`
rather than a `Nutrition`. Both live beside `libraryFacts` and `ladleNumber`,
and no view does its own prefixing.

Call sites, all of them:

| Surface | File |
| --- | --- |
| Card and row facts ("≈ 300 cal · 20g protein") | `Ladle/Design/RecipePresentation.swift` → `libraryFacts`, read by `RecipeGridCard`, `RecipeListRow`, `RecipeContextMenu` |
| Watch feed metadata | `Ladle/Library/WatchView.swift` |
| Recipe detail nutrition summary | `Ladle/RecipeDetail/RecipeMetadataBand.swift` → `RecipeNutritionSummary` |
| Nutrition sheet hero | `Ladle/Nutrition/NutritionView.swift` |
| Health export preview | `Ladle/Health/HealthExportSheet.swift` |

Cook mode shows no nutrition, so there was nothing there to mark.

Both `perServing` fallbacks — the one in `NutritionView` and the one in
`RecipeNutritionSummary` — construct an empty `Nutrition` for a recipe whose
serving basis is unusable, and both now carry `approximate` into it.

### The sheet

**No new line.** `NutritionNote.uncounted` already reads the recipe-level
`nutrition` uncertainty ("1 of 2 ingredients not counted: garam masala.") and
`NutritionView.servingNote` already renders it; `IngredientList` already puts
the per-row note under each skipped ingredient. Both landed with the
September 2 work. The names travel as uncertainties and are not repeated on
the nutrition DTO, so there is exactly one source for them and this change
adds no second one.

The note is deliberately **not** gated on `approximate`. Recipes enriched
before PR #104's `nutrition_skips` table existed carry their summary and
`approximate: false` until the host is backfilled; the note is the truthful
thing about them, and hiding it behind the marker would lose it.

### VoiceOver

`NutritionView`'s hero label was `"Estimated 520 calories"`. It now reads
`"About 520 calories"` when the total is incomplete and `"520 calories"`
otherwise — the word the metadata band already uses for a time it is unsure
of. It no longer says "Estimated"; that word is still spoken by the sheet's
own "Nutrition is estimated from the imported recipe." line and the detail
band's pill.

**Known rough edge:** cards read `libraryFacts` verbatim as their label, so
VoiceOver announces the glyph as "almost equal to 300 cal". Understandable,
and giving cards a second spoken string would put per-view string surgery back
where this change took it out. Left as is.

### Health export

`HealthExportPayload.approximate` sits beside `isEstimated`, and the preview
marks the calorie row. The sheet gained one line above the permission note,
shown only when the payload is approximate: the nutrition sheet's own
`uncountedNote`, threaded through, so the export repeats the sheet rather than
inventing a second wording. When there is no note — an app whose recipe
predates the summary — it falls back to one plain sentence.

The export button is untouched. A total short by a spice blend is still the
best figure anyone has, and refusing to write it would leave the day emptier
than it was. But Apple Health keeps a number long after the recipe screen is
closed, and the confirmation is the last place the shortfall can be read.

### The editor

`RecipeDraft.Nutrition.approximate` is carried and never shown. Without it, a
cook fixing a typo in the calories would save `approximate: false` over the
pipeline's own finding while the ingredient rows went on naming what is
missing — the client-side twin of the `PUT /recipes/{id}` overwrite PR #104
avoided by deriving the marker from the skip rows.

## Tests

`Packages/LadleCore/Tests/LadleCoreTests/`

- `NutritionTests` — `scaled` carries the marker; a payload without the key
  decodes as complete; an encode/decode round trip preserves it.
- `RemoteContractTests` — `recipe-approximate-nutrition.json` decodes with the
  marker, the ingredient's own "Not counted" note and the recipe-level
  summary; the same fixture with the key removed decodes as complete;
  `recipe-ready.json` is not marked. Added `fixtureObject` beside
  `decodeFixture` for the key-removal case.

`LadleTests/`

- `NutritionNoteTests` — the helper's output, marked and bare and absent;
  the pre-backfill recipe whose note is true while its marker is false; the
  `insufficientCoverage` sample blocker reworded to `invalidYield`, which is a
  whole-recipe failure that still exists after #104.
- `LibraryViewModelTests` — `"≈ 300 cal · 20g protein"` for an incomplete
  total, and a bare line for both an estimated-but-complete panel and a
  labelled one. (`testDenseArchiveFactsOnlyMarkEstimatedCaloriesApproximate`
  was a stale name from before cards had any marker; it is now
  `…LeaveAnEstimateThatCountedEverythingUnmarked`.)
- `HealthExportViewModelTests` — the marker survives the serving scale and
  reaches the written payload, and the export still happens.
- `RecipeEditorViewModelTests` — editing the calories does not clear it.

No new files, so no `xcodegen generate` and no project diff.

## Verification

```
swift test --package-path Packages/LadleCore
  Test run with 62 tests in 10 suites passed

xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,id=<an iPhone 17 Pro on iOS 26.5, \
                created for this run and deleted after>' \
  -only-testing:LadleTests
  Test Suite 'All tests' passed
  Executed 469 tests, with 1 test skipped and 0 failures (0 unexpected)
  ** TEST SUCCEEDED **
```

No UI test pinned the old glyph or the old VoiceOver label, so
`-only-testing:LadleTests` covers the change. `git diff --check` is clean.

## Not done here

- **The host is not backfilled.** Until
  `scripts/refresh_recipe_nutrition.py --apply` runs, recipes enriched before
  PR #104 arrive with their "N of M not counted" notes and `approximate:
  false`, so they show the sheet's line and no marker. PR #104's own doc
  records this as the deploy step.
- No demo fixture carries the marker, so the "Overeast UI validation"
  scenarios show it only against a live server.
- The ops-dashboard panel and the curated table are the later halves of #37.
