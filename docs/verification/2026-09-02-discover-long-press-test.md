# The Discover long-press test presses the row again

Date: September 2, 2026
Issue: [#65](https://github.com/chetangoel01/recipe-app/issues/65)
Status: **fixed and verified on the review simulator.**

## Purpose

`DiscoverInteractionUITests.testDiscoverRecipeSupportsTapAndLongPress` failed
on `main` regardless of what else was in the tree: the long press never opened
the context menu, so "View Recipe" was never there to tap. The feature was
fine — a manual long press on the same build opens the menu, captured in
`captures/2026-09-02-context-preview-environment/`. This is the test finding
its element and then pressing somewhere the element is not.

Nothing in the app's behaviour changes. `DiscoverView.swift` is untouched; the
only edit is to the test, and no assertion was removed.

## What `firstMatch` actually was

The issue guessed that `firstMatch` had drifted onto a shelf card in one of
the rails. It had not, and it cannot: a card's identifier is
`discover.card.<shelf>.<original URL>`, which does not begin with
`discover.http`. Only `DiscoverRecipeRow` — identifier
`discover.<original URL>` — matches that predicate.

From the run's session log, the element the press resolved to and its frame:

```
Press Any (First Match)[0.15, 0.50] for 1.0 seconds
    Find the "discover.https://www.tiktok.com/@chebbo/video/7364345055881989392" Other

Other, {{16.0, 829.7}, {370.0, 111.3}},
  identifier: 'discover.https://www.tiktok.com/@chebbo/video/7364345055881989392'
```

That is the right element — the first row under "All recipes". The press is
what went wrong:

```
Requesting local synthesis of event:
<XCSynthesizedEventRecord 'long press display 1'>
	Touch down at 71.5, 885.3, offset=0.00s
	Touch up at 71.5, 885.3, offset=1.00s
```

The simulator is an iPhone 17 Pro, 1206 x 2622 pixels at 3x, so **402 x 874
points**. The row's frame starts at y = 829.7 and is 111.3 points tall, so it
runs to y = 941 — only its top 44 points are on the screen at all. The
normalized offset therefore computes

```
x = 16    + 0.15 * 370.0 =  71.5
y = 829.7 + 0.50 * 111.3 = 885.3
```

and **885.3 is 11.3 points below the bottom edge of the screen**. The touch
was synthesised outside the display. `waitForExistence` — line 19 of the
version on `main` — passed anyway, because an element in a `LazyVStack` exists
long before it is visible,
which is precisely why the failure read as "the menu did not open" rather than
"the row is not on screen".

The trailing evidence agrees. By the time the test gave up on line 30 the app
had left Discover's list entirely:

```
Button, identifier: 'BackButton', label: 'Discover',
Button, identifier: 'person.crop.circle', label: 'Account',
Button, label: 'Start Cooking',
Button, label: 'Ingredients', Selected,
```

That is the read-only Discover detail the test wanted to reach, arrived at
without the menu it was written to exercise — so "View Recipe" was never in
the hierarchy to tap. What the system did with a touch synthesised past the
edge of the display is not in the log and is not worth guessing at; what is in
the log is that it was not a long press on the row.

### Why it started failing

Not bisected, and deliberately so — the fix does not depend on the answer. But
it is worth saying what it is *not*. The shelves did not do this on their own:
the rails' own verification note recorded this test green on 2026-09-01, with
both rails already present and on the same 402 x 874 geometry — `Executed 1
test, with 0 failures (0 unexpected) in 16.922 seconds`. And no layout code is
responsible either; `DiscoverView.swift` has not changed since `f629af5`.

What the rails did was spend the margin. They pushed the press point to within
a few tens of points of the bottom edge, and something since — content heights
above the row, not the row's own code — took the last eleven. A test whose
press point sits that close to an edge is one change away from failing however
that change arrives, which is the thing worth fixing rather than the eleven
points.

## The fix

The test keeps the same target — the first "All recipes" row, matched by the
same `discover.http` predicate — and stops assuming that finding it puts it
under the finger.

- **Scroll before pressing.** A bounded loop swipes up (at `.slow` velocity,
  so there is no flick momentum to overshoot with) until the row is hittable
  *and* the exact point this test presses is inside `app.frame`.
- **Assert what actually broke.** The gate before the press is
  `row.isHittable && app.frame.contains(pressPoint.screenPoint)`, and its
  failure message prints the row frame and the app frame. Next time the layout
  above the row grows, the test says "the row is not on screen, here are the
  numbers" instead of "the menu did not appear".
- **Say why that point.** 15% across, 50% down is over the row's artwork —
  inside the button that opens the recipe, and as far as the row gets from the
  Save control on its trailing edge, so the long press cannot be mistaken for
  a press on Save. That reasoning is now in the test rather than implied.

The three things the test proves are unchanged and none of its assertions were
deleted: a long press on a Discover recipe opens the context menu with "View
Recipe" and "Save Recipe"; "View Recipe" pushes the read-only Discover detail;
that detail carries the "Account" toolbar button and no "Recipe options" menu.

### No app change was needed

`DiscoverView.swift` already gives the row a stable identifier, and
`discover.http` already separates rows from cards, so the smallest change was
none at all. `RecipeContextMenu.swift` is untouched.

## Verification

`xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests -destination
'platform=iOS Simulator,id=54720038-6397-4145-B02F-8C9B639C69FE'` on the
iPhone 17 Pro (iOS 26.5) review simulator.

Red first, the single test on `main` — this is the run the evidence above
comes from:

```
-only-testing:LadleUITests/DiscoverInteractionUITests/testDiscoverRecipeSupportsTapAndLongPress
Executed 1 test, with 3 failures (0 unexpected) in 15.632 seconds
DiscoverInteractionUITests.swift:23: XCTAssertTrue failed
DiscoverInteractionUITests.swift:24: XCTAssertTrue failed
DiscoverInteractionUITests.swift:30: Failed to tap "View Recipe" Button
```

Green, twice, so the fix is not flaky. The whole file both times, because the
other six tests share the same launch path and had to be confirmed alongside
the fixed one:

```
-only-testing:LadleUITests/DiscoverInteractionUITests
Executed 7 tests, with 0 failures (0 unexpected) in 118.547 seconds
Executed 7 tests, with 0 failures (0 unexpected) in 119.925 seconds
```

`testDiscoverRecipeSupportsTapAndLongPress` itself took 16.718 s and 17.201 s.
One swipe is enough in both runs — the activity trace shows a single `Swipe up
Target Application` inside the test — so the loop's cap of four is three
spare, not a budget it is living on.

## Files

| File | Change |
| --- | --- |
| `LadleUITests/DiscoverInteractionUITests.swift` | Scroll the first "All recipes" row on screen and assert the press point before pressing it |
| `docs/verification/2026-09-02-discover-long-press-test.md` | This note |
