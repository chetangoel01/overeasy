# A reviewed import leaves the Inbox

Date: September 7, 2026
Issue: [#91](https://github.com/chetangoel01/recipe-app/issues/91)
Status: **fixed, red-green on the review simulator.**

## What was wrong

TestFlight, build `20260903.1`: *"Recipe marked reviewed but inbox doesn't
dismiss"*, with a screenshot of the **Couldn't read the recipe** failure
sheet.

The issue's reading was that the job was `.failed` and so failed the first
condition of the guard in `LibraryViewModel.completeReview`:

```swift
guard job.status == .needsReview,
      job.reviewCandidate == nil,
      job.reviewRecipeID == recipeID else { return job }
```

It is the **third** condition that fails, and the job is `.needsReview`
throughout. `ImportCoordinator.apply(_:to:)` finished a live needs-review
import with

```swift
job = try job.transitioning(to: .needsReview)
```

`ImportJob.transitioning` does nothing for the `.needsReview` case, so
`currentRecipeID` stayed `nil`. `reviewRecipeID` is
`currentRecipeID ?? candidateRecipeID`, so it was `nil` too, the guard could
never match any recipe, and the job was returned untouched. Every live import
that came back needing review kept its Inbox row forever, whether or not it
had ever failed.

The failure sheet in the screenshot is a second symptom of the same nil.
`ImportInboxView` routes a row by what the job knows: `.failed` and
`reviewCandidate` rows open the recovery sheet, a row with a findable recipe
opens the review, `.parsing` opens progress — and anything else falls to a
final `else` that also opens `FailedImportSheet`. A needs-review job that
names no recipe lands in that `else`. So the row the tester tapped after
reviewing showed him "Couldn't read the recipe" for an import that had in
fact succeeded. `LibraryViewModel.title(for:)` has the same dependency: the
stale row could not even print the recipe's name.

Nothing was wrong with the guard, and nothing was wrong with `.failed`. Of
the three candidate fixes the issue listed — widen the status guard, clear a
lingering `reviewCandidate`, link the recipe back through `reviewRecipeID` —
only the third applies. There is no path that leaves a `.failed` job holding
a recipe: `apply` clears `candidateRecipeID` and `reviewCandidate` on the way
into `.failed`, and `createManualRecipe` never touches a job at all.

## The fix

One line in `Ladle/Import/ImportCoordinator.swift`:

```swift
job = try job.awaitingReview(recipeID: recipe.id)
```

`awaitingReview(recipeID:)` is the existing `ImportJob` transition for this —
it is what `PreviewFixtures.reviewJob` already used, which is exactly why the
seeded library never showed the bug. It performs the same
`transitioning(to: .needsReview)` and then sets `currentRecipeID` when there
is no candidate to defer to, so a re-import's accept/keep decision is
untouched (that branch returns earlier, through `awaitingRemoteReview`).

Nothing else changed. `completeReview` now matches on its own terms, and the
Inbox's existing rule that `.ready` jobs are not actionable removes the row.
No deletion, no new "resolved" state — the import succeeded, with the cook's
help.

### A visible side effect, on purpose

A live needs-review row now knows its recipe, so it renders the recipe's
title and byline and opens the review when tapped, instead of falling through
to the failed-import sheet. That is the behaviour the seeded review row has
always had.

### What this does not do

Rows already persisted by a shipped build keep their `nil` recipe link; no
migration was added, per the issue's "no deletion, no resolved state". A cook
carrying one can still swipe it away with **Discard**. Worth a follow-up if
more than one report arrives.

## The four exits from the failure sheet

Chetan did not remember which button he tapped, so all four were walked
against the seeded `standard` fixtures — the failed `carbonara` job in
`PreviewFixtures.importJobs` — through the real `ImportCoordinator.retry` and
the real `DemoImportService` the simulator runs.

| Exit | Seeded-sim outcome | Left a row before the fix? |
|---|---|---|
| Retry import | `.ready`, recipe `.ready` | No — the demo slug has no failure keyword, so the retry succeeds outright |
| Add correction notes | `.ready`, recipe `.ready` | No — any non-empty note makes `DemoImportService` return ready |
| Paste recipe details | `.ready`, recipe `.ready` | No — pasted text always returns ready |
| Create manually | `.ready`, recipe `.ready` | No — the sheet submits title + body as pasted text, so it is the row above |

`DemoImportService` can only reach `.needsReview` from a slug containing
`review`, and that check sits below the pasted-text, correction-notes and
failure-keyword branches. So no exit from the failure sheet can reach review
in the demo, and none of the four reproduces the report on the seeded
simulator. That is the honest result, not evidence the paths are safe: all
four hand the job back to the same importer, so all four can come back
needing review against the live backend, and all four went through the nil
`reviewRecipeID` before this change. Each has its own unit test to prove it.

The report is reachable on the seeded simulator through a live import whose
slug asks for review, which is what the UI test below does.

## Tests

Red first, five unit tests against a stub service that answers `.needsReview`
for both submit and retry:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,id=<iPhone 17 Pro, iOS 26.5>' \
  -only-testing:LadleTests/ImportCoordinatorTests/testNeedsReviewImportLinksItsRecipeToTheInboxJob \
  ... four more ...
Executed 5 tests, with 15 failures (0 unexpected) in 0.418 seconds
```

Each failed three ways, which is the whole bug in one line of output:
`reviewRecipeID` nil, the job still `.needsReview` after
`completeReview`, and `actionableImportJobs` not empty.

Green, and the neighbouring suites that touch the same transitions:

```
-only-testing:LadleTests/ImportCoordinatorTests \
-only-testing:LadleTests/LibraryViewModelTests \
-only-testing:LadleTests/ReimportSafetyTests \
-only-testing:LadleTests/SharedQueueReconcilerTests \
-only-testing:LadleTests/DemoImportServiceTests
** TEST SUCCEEDED **
```

Full unit suite:

```
-only-testing:LadleTests
Executed 466 tests, with 1 test skipped and 0 failures (0 unexpected) in 8.266 seconds
```

UI, `StateScenarioUITests/testReviewedImportLeavesTheInbox` — import a
needs-review link, open the Inbox row, mark reviewed, and watch the row go:

```
without the fix: line 259 XCTAssertTrue failed — no Inbox row labelled
"Sunday Tomato Ragu" exists at all
with the fix:    passed (36.024 seconds)
```

The red is sharper than the assertion it was written for. Before the fix the
row could not name its own recipe, so the test never got as far as tapping
it; `title(for:)` reads through the same `reviewRecipeID`.

Full UI suite, because a needs-review row now renders and routes differently:

```
-only-testing:LadleUITests
Executed 29 tests, with 0 failures (0 unexpected) in 555.396 seconds
```

## Files

| File | Change |
|------|--------|
| `Ladle/Import/ImportCoordinator.swift` | a completed needs-review import names its recipe on the job |
| `LadleTests/ImportCoordinatorTests.swift` | five tests — a fresh import and each of the four sheet exits — plus a `NeedsReviewImportService` stub |
| `LadleUITests/StateScenarioUITests.swift` | `testReviewedImportLeavesTheInbox` |

No file was added or removed, so `xcodegen generate` was not needed and
`Ladle.xcodeproj` is untouched.

## How this was verified

Debug builds of the `LadleAllTests` scheme. The unit red run and the first
green run were on the house simulator
`54720038-6397-4145-B02F-8C9B639C69FE` (iPhone 17 Pro, iOS 26.5). Every UI
run and the full 466-test unit suite were on a clean iPhone 17 Pro, iOS 26.5
simulator created for this work and deleted afterwards: two other agents were
driving the house device at the time, and the UI test died with "Test crashed
with signal kill" until it had a simulator to itself.
