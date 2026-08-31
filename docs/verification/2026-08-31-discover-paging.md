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

---

# Addendum: source engagement counts and Most liked

Commit: `3408fd2`

## Why

Ranking existed only for saves inside Overeasy. yt-dlp already returns like,
view, comment and repost counts plus the publish timestamp on every
acquisition — `_media_from_payload` read `uploader` and `duration` and dropped
the rest.

Verified before building, against a live TikTok video: `like_count 4331`,
`view_count 107200`, `comment_count 78`, `repost_count 38`, `timestamp`. A
second fetch minutes later read `4334` — the drift this design has to live
with, observed rather than assumed.

**This also unblocks "recent"**, which an earlier note recorded as impossible:
the publish date was in the payload all along. It is stored but not exposed.

## Provider coverage — the important limitation

| Platform | Metadata source | Counts? |
| --- | --- | --- |
| TikTok | yt-dlp | **yes** |
| YouTube | yt-dlp | **yes** |
| Instagram | `/embed/captioned/` endpoint | **no** |

Instagram takes the embed path because yt-dlp is cookie-gated there — checked
against a live reel URL, which returned "Instagram sent an empty media
response... use --cookies-from-browser". The embed's `gql_data` may carry
counts, but that could not be confirmed without a known-good reel URL, so it
is untested rather than ruled out.

So Most liked is a TikTok/YouTube ranking. If Instagram is a large share of
the corpus, it is systematically absent from the top of that feed.

## Shape

Typed nullable columns on `source_videos` — `like_count`, `view_count`,
`comment_count`, `repost_count`, `published_at`, `counts_refreshed_at` — not
keys inside the existing `source_metadata` JSON, which stays empty. Discover
ranks on these, and a JSON expression takes no plain index and cannot sort
NULLs last. Migration 0019, partial index on `like_count`.

## Refresh

The chosen behavior was "reload when a user asks for the same video through
the import". That is the cache-hit path — and it returned *before*
acquisition, so the obvious write site in `complete_shared` would only ever
have written once per source revision, which is the snapshot behavior that was
explicitly declined.

The cache-hit branch now calls a new `VideoAcquirer.refresh_counts` — one
yt-dlp JSON read, no media download — **outside** the transaction, because the
job row is held `FOR UPDATE` inside it. Throttled by `counts_refreshed_at` to
twice a day per source. It never raises: a failed refresh leaves the previous
snapshot, and a provider returning nothing does not erase what is stored.

## Ranking

`sort=mostLiked` orders by `like_count DESC NULLS LAST, saved_count DESC,
source_video_id`.

- **NULLS LAST** because nothing is backfilled — most of an existing corpus
  has no counts, and Postgres `DESC` puts NULLs first, which would open the
  feed with countless rows on day one.
- **saved_count** tiebreak degrades the ranking to the popular order while
  counts accrue.
- **source_video_id** keeps the order total, or the offset cursor skips and
  repeats rows across the ties the null tail is full of.

Covered by an integration test that asserts counted sources lead, uncounted
ones fall back to save order, and paging walks the ranking without repeats.

## Not done

- No backfill. Counts accrue from the next import of each source onward.
- `published_at` stored, no `recent` sort exposed.
- View, comment and repost counts stored, not surfaced.
- The health probe's `expected_revision` was stale at `0017` after migration
  0018; their guard test caught it and it now reads `0019`.

---

# Addendum 2: end-to-end run against the live stack

Commit: `6bff7b6`. Run on 2026-08-31 against the local docker stack in
`LADLE_WORKER_PROVIDER_MODE=live`.

## Two blockers that had nothing to do with this work

**The local stack could not import anything, and had not since 25 Aug.**
`docker-compose.yml` defaults `LADLE_USDA_NUTRITION_ENABLED=true`, no USDA key
exists locally, and the worker raises `RuntimeError: nutrition requires a USDA
API key` while *constructing the orchestrator* — so every import failed in
~12ms and surfaced as `networkUnavailable`, which is misleading. Worked around
with `LADLE_USDA_NUTRITION_ENABLED=false` appended to `Backend/.env` (original
saved as `.env.bak-before-e2e`). Chetan believes the real key is on the VPS.

**The `migrate` image was seven migrations stale.** `docker compose build api
worker` does not rebuild `migrate`, which carries its own image tag, so the
local database sat at `0012` while head was `0019`. Rebuilding `migrate`
applied 0013–0019 cleanly.

Neither was caused by this change, but both would bite anyone setting the
stack up.

## Results

| Source | Import | Counts captured |
| --- | --- | --- |
| TikTok — @feelingtastyy | ready | 54,600 likes / 722,400 views / 188 comments / 10,200 shares / published 2025-11-19 |
| TikTok — @arianamariaa11 | failed | `insufficientTextEvidence` — no usable recipe text |
| YouTube Short | needsReview | 624,765 likes / 12,561,733 views / 2,700 comments / published 2024-06-01 |
| Instagram — DS3DPehEnpA | needsReview | 272,605 likes / 3,951,951 views / 2,027 comments |
| Instagram — DWOyR1zE7HB | failed | `insufficientTextEvidence` |

Two failures are content outcomes, not defects: the pipeline judged those two
posts to carry too little recipe text. Worth a look if you disagree with the
call on them.

`GET /v1/recipes/discover?sort=mostLiked` on live data put the counted recipe
first and fell back to save order (6, 5, 3, 1…) for the rest — NULLS LAST
behaving as designed outside the test fixtures.

## What the run exposed

TikTok captured nothing at first, through two layers:

1. **TikTok rejects yt-dlp from the container's address.** The same binary
   version that works from a laptop fails inside Docker. The lock was also two
   months stale (2026.7.4), so it was upgraded to 2026.8.19 — which did not
   fix it, and is recorded here so nobody re-tries that.
2. **The free TikTok page scrape supplies metadata**, so the paid Supadata
   metadata call that carries counts was never reached.

Both are now moot: the TikTok page blob already contains `stats.diggCount`,
`playCount`, `commentCount`, `shareCount` and `createTime`, so counts come
free from a page already being fetched. Supadata's `stats` and `createdAt` are
mapped too, for whenever the free path yields nothing.

Note the refresh path is still free-path-only by design, so a TikTok cache-hit
refresh now works via the page scrape rather than yt-dlp.

## Still open

- The USDA key, if nutrition is wanted locally. Card facts show
  "cal · protein", which no imported recipe here exercised.
- `published_at` is absent for Instagram — the embed carries no timestamp — so
  a future "recent" sort would cover TikTok and YouTube only.
