# Discover offers a fresh page when you scroll back to the top

Date: September 1, 2026
Issue: [#28](https://github.com/chetangoel01/recipe-app/issues/28)
Status: **built and verified on the local stack.**

## What was asked, and what was built

From the UI feedback triage of August 31:

> "I want to add refresh on when the user goes all the way up."

The literal version — reaching the top replaces the list — is the one iOS
deliberately avoids, and the issue says why: scrolling up is usually how
someone returns to a row they meant to keep, so swapping the feed at that
moment takes away the thing they scrolled up for. The implementation brief
offered three shapes and recommended the first, which is what this is:
**reaching the top fetches page 1 quietly, and if it differs from what is on
screen a "New recipes" pill appears under the navigation bar.** The ground
only moves when the cook taps it.

This was blocked on #26 until today. Before it, a refresh returned
byte-identical rows and the whole feature would have been a spinner over an
unchanged list. Now a fresh pin genuinely re-ranks, which is what gives the
pill something to say — and, less comfortably, is also what made the recording
question below unavoidable.

## When the quiet fetch fires

On the loaded feed's `ScrollView`, `onScrollGeometryChange` watches two coarse
facts rather than the offset itself, so the observation runs when the scroll
crosses a threshold instead of on every frame:

```swift
let distance = geometry.contentOffset.y + geometry.contentInsets.top
isAtTop = distance <= 0
isAScreenDown = distance > geometry.containerSize.height
```

The brief's `contentOffset.y <= 0` is not enough on its own. Under the large
title and the search drawer the resting offset at the top is *minus* the inset,
so the raw value stays at or below zero well into the first screenful and "at
the top" would mean "somewhere in the first 150 points". Adding
`contentInsets.top` measures from the top of the content, which is what the
rule is about.

Five conditions, and all of them have to hold:

| Rule | Where | Why |
|---|---|---|
| The false→true edge of reaching the top | `DiscoverView.reachedTop` | Arriving, not resting there. Sitting at the top does not re-ask. |
| More than one viewport away since the last refresh | `hasScrolledAScreenAway` | A bounce is not a journey. The flag is spent on the attempt, so bouncing on the top edge cannot keep asking. |
| At most once a minute | `lastRefreshedAt` | One request a minute, however often the cook travels. |
| Never while a refresh is in flight, and never on `.loading` | `refreshQuietly` guards | The screen already has a spinner and an answer coming. |
| Never under a search | `isSearching` | Search results are what the cook typed for; offering to replace them is not a refresh. |

`lastRefreshedAt` is set by a pull, by a quiet refresh, and by taking the pill —
but **not** by a cold first load. A first load is the feed, not a refresh of
it, so a cook who opens Discover, reads a screen and comes back to the top may
still be offered something new.

Note what the viewport rule implies for a short feed: a list under two
viewports tall can never put the reader a full viewport from the top, so it
never offers a pill. That is the right degradation — a feed that short has
little to turn over — and it is why the demo feed cannot exercise the trigger
(see Verification).

`.refreshable` is untouched. A pull is still an immediate, visible refresh with
the banner. A pull that lands while a quiet fetch is still out wins: the page
in flight was ranked against the session the pull replaced, so it is dropped
rather than surfaced behind it.

## The pill

`DiscoverViewModel.refreshQuietly()` never writes `refreshState = .refreshing`,
so no banner appears while it runs, and it never replaces `state`. It stores a
`PendingPage` — the rows, the cursor, and the pin they were ranked under. If
the rows match what is on screen it is dropped without a word.

The comparison is page 1 against **the first page's worth** of the list, not
against the whole of it: after `loadMore()` the list is longer than a page and
comparing the whole thing would call every feed new.

The pill lives in the same `.safeAreaInset(edge: .top)` as
`DiscoverRefreshBanner` and is drawn by the same `DiscoverTopBar` — one strip
of `Surface.steel` with the same padding and hairline. A held page supersedes a
failure banner rather than stacking under it: it is the newer news, and two
bars would read as a pile-up.

Tapping it applies the held rows **at once** — they are already in hand, so a
spinner would be a wait for nothing — adopts the pin as the paging session,
reloads the two rails, and scrolls the list to the top.

Discover only. Watch shares the view model and passes `recordsSeenSources:
false`, which also switches the quiet path off: it is a video feed, not a list
with a top to come back to. Recipes is local, and the Inbox already announces
arrivals.

## The problem #26 created, and `record_impressions`

With #26 as merged, a request carrying `seen_before` **records the page it
serves**. A quiet fetch is exactly the thing that must not do that: it would
mark as read a page that is sitting behind a pill the cook may never tap, and
those rows would then be demoted out of the next session — buried without ever
having been shown.

`GET /v1/recipes/discover` therefore takes `record_impressions`, default true.
False keeps the demotion and drops the write:

| Fetch | `seen_before` | `record_impressions` | Effect |
|---|---|---|---|
| Quiet refresh at the top | a fresh pin | `false` | ranked against what the cook has read; nothing written |
| Taking the pill | the **same** pin | `true` (default) | the same rows, now recorded |
| Everything else (`load`, `loadMore`, pull) | as before | `true` | unchanged from #26 |
| Shelves, Watch | absent | n/a | unchanged; the parameter is ignored without a pin |

Applying re-fetches page 1 under the pin the quiet fetch used. The ranking is
deterministic and the quiet fetch wrote nothing, so nothing could have moved
between the two — the rows come back the same. The client shows **the recorded
page**, not the held one, so what the cook is looking at is exactly what the
server marked as read even in the rare case where the corpus changed in
between. If the recording fetch fails, the rows the cook took stay on screen;
they are the right rows, they simply are not written down yet.

The client only sends the parameter when it means something — with a pin, and
only when false — so shelf and ordinary page requests keep the shape they had.

## Files

- `Ladle/Library/DiscoverView.swift` — `PendingPage`, `refreshQuietly()`,
  `applyPending()`, the once-a-minute gate, the scroll observation,
  `DiscoverNewRecipesPill`, and `DiscoverTopBar` extracted from the banner
- `Ladle/Remote/DiscoverService.swift` — `recordsImpressions` on
  `DiscoverServing`, the query item, the demo service's shrug
- `Backend/ladle/api/routes/recipes.py`, `Backend/ladle/recipes/service.py`
- `LadleTests/DiscoverViewModelTests.swift`,
  `LadleUITests/DiscoverInteractionUITests.swift`,
  `Backend/tests/api/test_discover_paging.py`
- `Backend/ladle/api/openapi.py`, `Backend/docs/integration-reference.md`,
  `DESIGN.md`

No DTO changed, so `Contracts/Fixtures/*.json`, `Backend/tests/contracts/` and
`RemoteContractTests` are untouched. No file was added or removed, so the
generated project needed no `xcodegen generate`.

## Decisions the brief did not settle

- **Route and service, not the repository.** The brief named three layers.
  `record_discover_impressions` is already a separate repository call that the
  service gates on `seen_before`, so the flag belongs beside that gate and the
  ranking query is untouched. Adding a parameter to `repository.discover()`
  would have been a parameter nothing reads.
- **The recorded page wins.** Applying shows what the recording fetch returned
  rather than the held rows. In the deterministic case they are identical; when
  they are not, the invariant that matters — nothing is marked read that was
  not shown — is the one that survives.
- **Instant swap, recording behind it.** Taking the pill does not wait on the
  network. The alternative is a button that appears to do nothing for a few
  hundred milliseconds.
- **Page 1 against the first page on screen**, so a cook who has paged deep is
  not told the feed is new every time.
- **A cold first load does not start the minute**, as above.
- **The flag is spent on the attempt**, not on a successful fetch: after a
  gated return to the top the cook has to leave and come back again.
- **The pill supersedes the failure banner** when both could show.
- **`hasScrolledAScreenAway` and the scroll-to-top request live in the view**,
  not the view model: they are geometry, and the view model stays testable
  without one.
- **The quiet path is switched off wherever `recordsSeenSources` is false**,
  which is Watch. One flag already means "this surface is a reading position",
  and the pill is only meaningful where that is true.
- **A pull in flight beats a quiet page in flight**, guarded by comparing
  `sessionStartedAt` across the await rather than by the generation counter,
  which a pull deliberately does not bump.

## Verification on 2026-09-01

Backend, from `Backend/`:

- `uv run pytest tests/api/test_discover_paging.py -q` — **8 passed in 6.40s**.
- `uv run pytest tests/api tests/unit -q` — **701 passed in 23.96s**.
- `uv run ruff format --check .`, `uv run ruff check .`,
  `uv run mypy --strict ladle` — identical to the `origin/main` baseline
  captured before any edit: one unformatted file
  (`alembic/versions/0019_*.py`), two `I001` findings (`0020_*.py`,
  `0021_*.py`), five mypy errors in `ladle/acquisition/provider_chain.py` and
  `ladle/worker/runtime.py`. No new findings.

`test_a_quiet_page_demotes_without_recording` was written first and failed on
the untouched route: FastAPI ignores an unknown query parameter, so
`record_impressions=false` recorded the whole page and the assertion that the
impression table had not moved failed with three extra rows and two restamped
ones.

Client, under the watchdog (the process prints its results and then never
exits; `** BUILD INTERRUPTED **` at the end of the log is the watchdog, not a
failure):

- `-only-testing:LadleTests` —
  **Executed 406 tests, with 1 test skipped and 0 failures (0 unexpected)**.
- `-only-testing:LadleUITests/DiscoverInteractionUITests` plus
  `StateScenarioUITests/testLaunchLandsOnDiscover` —
  **Executed 11 tests, with 0 failures (0 unexpected)**.

The demo assertion was checked for vacuity by making `DemoDiscoverService`
return a *reversed* page whenever `recordsImpressions` is false — a demo server
that does turn over:

- `DiscoverViewModelTests.testTheDemoFeedNeverHasAnythingNewToOffer` failed for
  nine of the twelve scenarios (the three that never reach a loaded feed are
  the exceptions), and passed again once the hook was removed. **This is the
  assertion with teeth.**
- `DiscoverInteractionUITests.testReturningToTheTopOffersNothingNewInTheDemoFeed`
  still passed under the hook, both with flicks and with a slower stepped
  return. Six fixtures and two rails come to a little under two viewports, so
  the "more than a screen away" rule is only met by an overscroll bounce and
  the quiet fetch does not reliably run there at all. The test is kept as a
  screen-level smoke check and its doc comment says so.

The scroll-to-top on taking the pill was checked by hand on the review
simulator from the *bottom* of the feed — the case a `ScrollViewReader` anchor
inside a `LazyVStack` is known to get wrong. The pill stays pinned in the safe
area while the list scrolls under it, and tapping it from the last row lands
back at the rails.

## Local stack

`docker compose up -d --build api worker` from this worktree's `Backend/`,
then `curl --fail http://127.0.0.1:4112/health/ready` →
`{"status":"ready", …}` with every check ready.

With a fresh guest token (`discover_impressions` for that user only):

```
session 1  ?limit=3&seen_before=T0
  0 3ee9f171 Chicken Piccata Pasta
  1 bf0bce31 Red Thai Curry Shrimp Mince
  2 a387dafe Creamy Garlic-Lemon Chickpeas
→ 3 rows recorded, all stamped 02:44:34.347769+00

quiet      ?limit=20&seen_before=T1&record_impressions=false
  0 7ecb88f8 Cheesy Garlic Mozzarella Potato Balls
  1 c2ef02c6 Gorgeous Green Noodle Soup
  2 9a9ad96a One-Pot Lemon Orzo
  3 c963444f One-Pot Lemon Orzo
  4 caf10b45 Chicken Fusilli Pasta
  5 3ee9f171 Chicken Piccata Pasta
  6 bf0bce31 Red Thai Curry Shrimp Mince
  7 a387dafe Creamy Garlic-Lemon Chickpeas
→ still 3 rows, still stamped 02:44:34.347769+00

take       ?limit=20&seen_before=T1
  the same eight rows in the same order
→ 8 rows recorded
```

The three sources read in session 1 moved from positions 0–2 to 5–7 — demoted,
not dropped — and the quiet request wrote nothing at all: same keys, same
timestamps, to the microsecond. Taking the pill under the same pin returned
the identical page and recorded all eight, which is the determinism the design
leans on.

The stack was left running and healthy: `api` and `worker` rebuilt and healthy,
`beat`, `postgres`, `redis`, `minio` and `device-edge` untouched and still up.
Nothing on this branch was run against production.

## Captures

`docs/verification/captures/2026-09-01-discover-refresh-at-top/`

| File | What it is |
|---|---|
| `01-new-recipes-pill.png` | The pill, on the review simulator |
| `02-after-taking-the-pill.png` | The feed after tapping it: back at the top, pill gone |
| `03-local-stack-discover.png` | The Debug build against `http://api.ladle.localhost` |

**How 01 and 02 were produced, because it matters.** The local stack's Discover
corpus is eight sources, and a page is thirty, so the first load serves the
whole corpus and records all of it. Every source is then seen, they all land in
the same bucket, and the ranking comes back unchanged — there is nothing new to
offer and no pill can appear. Confirmed on the device: capture 03 is the real
feed, and scrolling a screen down and back up on it produced no pill, correctly.

So 01 and 02 come from the demo build with the same temporary
`DemoDiscoverService` hook used for the vacuity check above — a reversed page
for the quiet fetch only. It is not in the branch. That hook is also why 02
shows the *original* order rather than the reversed one: the hook only touched
the quiet fetch, so the recording re-fetch came back in the normal order and
won, which is the reconcile rule doing exactly what it is for.
