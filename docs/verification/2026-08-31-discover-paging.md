# Discover: cursor paging and server-side search

Date: 2026-08-31 · Branch: `ui/watch-recipe-polish`
Commits: `cc5d0b0` (backend), `cc84ec7` (client)

## Why

Asked whether Discover would scale to a corpus of ~1000 recipes. Loading would
have been fine — but only because the app could never load more than 30, and
that turned out to be the actual problem.

- The client sent no parameters; the backend defaults to `limit=30` (cap 100).
- `DiscoverPageDTO` had no cursor, so nothing could reach item 31.
- At 1000 recipes roughly 970 sources were permanently unreachable.
- The client-side search shipped hours earlier searched only those 30 rows, so
  "pasta" returned no results while matches sat just outside the window.

Performance was never the bottleneck. Reachability was.

## Backend (`cc5d0b0`)

`/v1/recipes/discover` takes `cursor`, `q` and `sort`.

**Cursor.** An integer offset, matching `/v1/recipes/sync`'s existing cursor
rather than inventing a second style. It counts **ranked rows consumed, not
items returned**: a ranked source whose extraction cache has gone stale is
dropped from `items` but still advances the cursor, so paging cannot stall on
one bad row. `has_more` comes from selecting one row past the limit, avoiding a
second count query.

**Search.** Matches `Recipe.title` and `Recipe.creator_name`, not the cached
template JSON. Those are real indexable columns and the rows being ranked are
exactly these; `template_json` is a `JSON` column and cannot be indexed for
text search. The trade: a saver who renamed their private copy can surface a
source whose displayed title differs from what matched. LIKE wildcards are
escaped, so searching `100%` is literal.

**Sort.** `popular` or `alphabetical`. The client's old Featured and Most saved
were the same order — the backend already ranks by save count.

**Migration 0018** indexes the columns the ranking groups and filters on. None
were indexed, so every request planned a sequential scan and hash aggregate
over `recipes` — invisible at a few hundred rows, and now run once per page
rather than once per feed.

**Deliberately not done:** no index for the search filter. An unanchored
`ILIKE` needs `pg_trgm` plus a GIN index, and `CREATE EXTENSION` may not be
permitted on this deployment. Left as a follow-up for when search gets slow,
rather than a migration that might fail on deploy.

**Also not done:** the ~2-queries-per-row N+1 in `repository.discover`
(`SourceVideo` then `ExtractionCache` per item). It is constant per request and
did not get worse with paging, so it stayed out of scope.

## Client (`cc84ec7`)

`fetchDiscoverRecipes()` becomes `fetchDiscoverPage(cursor:query:sort:)`.

- The view model owns `query`, `sort` and the cursor, and appends pages.
- **Dedupe on append.** A save between requests shifts the server's window, so
  the same source can arrive on two pages. Covered by a test.
- **Generation counter.** Every query or sort change bumps it; a page resolving
  after the criteria moved on is discarded. Without it a slow first request
  overwrites the results of a later search.
- **Debounce 300ms**, since each keystroke is now a round trip.
- **Prefetch** eight rows before the end, so scrolling does not hit a spinner.
- **Failure is non-destructive**: a failed page keeps the rows already on
  screen and stops walking rather than retrying the same cursor forever.
- The demo service pages and filters fixtures the same way, so the demo
  exercises paging instead of pretending the feed is one page.

## Verification

- New integration test against real Postgres: paging walks the corpus without
  repeats or gaps, search matches across pages (including a term only reachable
  beyond page one), search itself paginates, alphabetical orders the whole
  corpus, wildcards are literal, no-match is an empty page.
- Backend: `tests/api` + `tests/contracts` 43 passed, `tests/unit` 633 passed,
  ruff clean.
- iOS: `LadleTests` 358 passed (6 new paging tests), `LadleCore` 47 passed.
- Confirmed by screenshot on iPhone 17 / iOS 26.5: A-to-Z reorders the feed and
  updates the caption; searching "udon" narrows to the match.

## Follow-ups

- `pg_trgm` + GIN index when search slows.
- Fix the discover N+1 if request latency matters under load.
- `recent` / `quickest` sorts still need publish date and cook time on
  `DiscoverRecipe`.
