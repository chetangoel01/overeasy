# Two shelves lead Discover

Issue [#153](https://github.com/chetangoel01/overeasy/issues/153). The owner's
feedback: "A few too many shelves in the discover page. We want to do two
always and the rest is a scroll."

## Purpose

Discover drew every shelf above "All recipes": the two curated rails, then
every keyword shelf the server composed, up to eight in all. The ranked list
could start several screens down, and further still at large text sizes. Two
shelves now lead the screen and the rest are part of the scroll, so the list
starts on the first screen however many shelves the corpus earns.

## Decisions

The owner's, on September 17, 2026, against a live mockup:

- **Two lead shelves.** A count, not a fixed pair: the two are drawn from the
  curated rails and the keyword shelves alike.
- **Random pick on relaunch.**

Engineering calls, open to veto. The first two were on the mockup as such.

- **The pick holds for the launch.** A pull, a tab switch, a filter that
  leaves a shelf standing and the "New recipes" page all refetch the shelves
  and none of them reshuffles. It is the rule Watch already follows for its
  videos. Signing out and back in builds a new Discover, so it draws again.
- **One shelf after every third row**, in the same order as the draw. With
  about forty recipes live, six shelves land inside the first eighteen rows.
- **Leftovers follow the last row.** A slot depends only on a shelf's place in
  the order, so rows arriving never move a shelf already on screen. A shelf
  the loaded rows do not reach yet waits for them; once the list has ended it
  follows the last row instead, so it stays reachable.
- **A shelf in the list sits between two hairlines**: the row's own above it
  and one of its own below, with the same 24-point gap inside each. Without
  the second, the rows after a shelf read as that shelf's rows.
- **Demo and UI-test runs draw nothing.** The shelves stay as fetched, so the
  two rails lead and captures and UI tests are the same on every launch.
  `LadleRuntime` decides this beside the identical rule for Watch.
- **The order only grows.** An id outlives its shelf, so a shelf that a filter
  or a search took away comes back where it was. A shelf that first arrives
  later in the launch is drawn in behind the ones already placed. One
  consequence: a rail that failed on the first load and arrives on a later
  one joins the back of the order, and leads only if nothing ahead of it can.
- **Only the rows are lazy.** See below.

Unchanged: searching hides every shelf; a saved recipe leaves every shelf, and
a shelf under three cards is dropped; a keyword shelf keeps "See all" and
hides while its keyword is the filter; rails keep their captions and have no
"See all"; a shelf that fails to load is simply absent; "All recipes" and the
sort caption sit directly above the first row. The server is untouched and
`LADLE_DISCOVER_SHELF_MAXIMUM_COUNT` stays where it was. The server's order
still decides which shelves exist and the order they arrive in; the draw only
decides where each is placed.

## Consequences worth knowing

- **Losing a lead moves the shelves behind it.** When a save takes a lead under
  three cards, the next shelf in the order moves up out of the list and every
  later shelf moves up one slot. The issue asks for exactly this, and it needs
  a lead holding exactly three cards, but it is a visible move.
- **A save shifts later shelves by one row.** A shelf stays under "every third
  row", so when a row above it leaves, the shelf now follows the next one.
- **Shelves are not drawn when the first page fails.** `DiscoverViewModel`
  still holds them, as before, but the failed state has no feed to put them
  in. That predates this change and is left alone.

## How it works

`DiscoverViewModel` takes `shuffleShelfIDs`, which defaults to a real shuffle,
and keeps `shelfOrder`. A `didSet` on `shelves` hands any id it has not seen
to the shuffle and appends the result, which covers `load()`,
`applyPending()` and `save()` without touching them. `visibleShelves` applies
the same three eligibility rules as before, in the drawn order. `leadShelves` is
its first two and `feedShelves` the rest, so the fallback needs no code of its
own: whatever drops out, the next shelf is already there.

`DiscoverShelf.feedSlot(_:rows:hasMore:)` is the whole placement rule. Shelf
*n* of the list, from zero, follows row 3*n* + 2; past the loaded rows it is
nil while more pages exist and the last row once they do not. `feed(_:)` asks
the view model which shelves follow each row.

## Only the rows are lazy

`feed(_:)` was one `LazyVStack`. With shelves free to change places that broke
in a way the old layout could not: when a save changed which shelves lead
while the cook was down the list, the viewport jumped to a different part of
the feed, and on the way back up the first shelf came to rest about 20 points
too close to the search field and stayed there. A lazy stack places what it
has not measured by estimate. The base build does not do this, because its
first two shelves never change.

The top anchor, the two lead shelves and the "All recipes" header are now in
a plain `VStack`, and `rows(_:)` holds the lazy stack beneath them. After the
same save the rows stay under the cook's finger, shifting only by the change
in the lead shelves' height, and the top rests where it should. Two shelves
cost nothing to keep alive. Paging is still lazy: with a temporary sixty-row
demo corpus the second page was requested only as the list neared its end,
not at launch.

## Affected components

- `Ladle/Remote/DiscoverService.swift` — `DiscoverShelf.leadCount`,
  `feedInterval` and `feedSlot(_:rows:hasMore:)`.
- `Ladle/Library/DiscoverView.swift` — `DiscoverViewModel.shuffleShelfIDs`,
  `shelfOrder`, `leadShelves`, `feedShelves` and `feedShelves(afterRow:of:)`;
  `visibleShelves` in the drawn order; `feed(_:)` split into the lead block
  and `rows(_:)`; `shelfView(_:)` so the shelf is built in one place.
  `DiscoverShelfView` itself is unchanged.
- `Ladle/App/AppBootstrap.swift`, `LadleApp.swift`, `RootView.swift` and
  `Ladle/Library/LibraryView.swift` — carry `shuffleShelfIDs` from
  `LadleRuntime` to `DiscoverView`. Watch's own view model draws no shelves
  and takes the default.
- `LadleTests/DiscoverViewModelTests.swift` and
  `LadleUITests/DiscoverInteractionUITests.swift`.
- `DESIGN.md` — the rule, under Discover and account. The
  [September 1](2026-09-01-discover-shelves.md) and
  [September 7](2026-09-07-keyword-shelves.md) records carry a note.

No file was added or removed, so the generated project is unchanged.

## Verification

Three tests carry the change, written first. Against stubs that compiled but
kept the old behaviour they failed and nothing else did — 55 tests, 12
failed assertions, all in these three — and they pass now.

- `testTwoShelvesLeadAndTheKeywordShelvesArriveNamedInTheFeed` replaces the
  test that pinned "keyword shelves sit after the two rails".
- `testTheShelfDrawHoldsForTheLaunchAndALostSlotPassesOn` injects a shuffle
  that reverses the first draw only, so a second draw would show. Keyword
  shelves lead; the order survives a pull and the "New recipes" page; a save
  that takes a lead under three cards hands its slot to the next shelf.
- `testFeedShelvesTakeEveryThirdRowAndTheLeftoversFollowTheLastOne` covers
  `feedSlot`: seven rows and three shelves with and without more pages, and a
  list shorter than one interval.

Three existing tests assert shelf order and now inject the as-fetched order;
what they assert is unchanged. The search, three-card, failure and save tests
are untouched and pass.

On a private iPhone 17 Pro simulator, iOS 26.5:

| Run | Result |
| --- | --- |
| `LadleTests` | 593 tests, 1 pre-existing intentional skip, 0 failures |
| `DiscoverInteractionUITests` | 10 tests, 0 failures |
| `RecipesFilterMenuUITests` | 5 tests, 0 failures |

`testSeeAllOnAKeywordShelfNarrowsTheListBeneathIt` still finds the Weeknight
shelf, now under the third row, and "See all" still narrows the list and
hides the shelf.

Nothing automated covers the layout: where a shelf sits among the rows, its
hairlines, or the lazy-stack fault above. The fault needs the lead shelves to
change, which a UI run cannot stage because it draws nothing, and the project
has no pixel comparison. The captures and the checks below are the evidence.

Looked at with temporary edits that are not in the branch:

- The demo order reversed, so a keyword shelf led with its "See all" and a
  rail sat in the list with its caption. Saving the Lemon Orzo row took
  Weeknight under three cards: Quick dinners and New to Overeasy led, and no
  shelf was left in the list. This is also how the lazy-stack fault was found
  and the fix confirmed.
- A sixty-row demo corpus with six keyword shelves: three rows between one
  shelf and the next, the last shelf under row 18 and plain rows after it, and
  the second page requested only as the list neared its end.
- The same corpus cut to eight rows, so the list ends before every shelf has
  a slot: the leftover shelves stacked after the last row, one hairline
  between each, and the list ended under the last of them.

## Captures

The demo corpus is six dishes and composes one keyword shelf, so a demo run
can show only one shelf in the list. Fixtures were not padded to show more.
The top of the screen is the same before and after in a demo run, because the
rails lead either way; the difference is what follows them.

| | |
| --- | --- |
| [Before](captures/2026-09-17-discover-two-shelves/01-before-third-shelf-above-the-list.jpg) | A third shelf above "All recipes" |
| [After, same scroll](captures/2026-09-17-discover-two-shelves/02-after-list-starts-under-two-shelves.jpg) | The list starts under the second shelf |
| [Top, dark](captures/2026-09-17-discover-two-shelves/03-after-top-dark.jpg), [light](captures/2026-09-17-discover-two-shelves/04-after-top-light.jpg) | Two shelves, then "All recipes" |
| [Shelf in the list, dark](captures/2026-09-17-discover-two-shelves/05-after-shelf-in-the-list-dark.jpg), [light](captures/2026-09-17-discover-two-shelves/06-after-shelf-in-the-list-light.jpg) | Weeknight under the third row |
| [List resumes](captures/2026-09-17-discover-two-shelves/07-after-list-resumes-dark.jpg) | The second hairline, then rows four to six |
| [Largest text](captures/2026-09-17-discover-two-shelves/08-after-shelf-in-the-list-largest-text.jpg), [below it](captures/2026-09-17-discover-two-shelves/09-after-list-resumes-largest-text.jpg) | The same shelf at the largest accessibility size |

At the largest size the shelf's title breaks as "Week-night" beside "See all".
`DiscoverShelfView` is unchanged and did the same above the list; it is not
addressed here.
