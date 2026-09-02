# Discover stops showing you what you just saw

Date: September 1, 2026
Issue: [#26](https://github.com/chetangoel01/recipe-app/issues/26)
Status: **built and verified on the local stack.**

## What was wrong

Discover ranks the whole public corpus by aggregate saves, and that ranking
only turns over when somebody saves something. A cook who opens Overeasy twice
in an afternoon sees the same rows twice; pull to refresh re-fetches the same
list. The owner's decision on the issue was explicit about which of the two
candidate fixes to take:

> "I think it should be an exclude recently seen, and when we pull to refresh,
> we see a new list of recipes."

A seeded shuffle would have given the same recipes in a new order. Excluding
recently seen gives *different* recipes, and that costs per-user state the
server did not have.

## Demote, don't exclude

The table records what was served; the feed sorts it down rather than removing
it. That one choice answers two of the requirements the decision raised on its
own:

- **The floor.** Excluding needs a rule for what happens when the exclusion
  set swallows a page — start letting things back in, oldest first, or return
  a short page. Demotion needs no such rule: once everything is seen, every
  source is in the same bucket and the plain ranking comes back. A heavy cook
  gets a stale feed, never an empty one.
- **One query, not two.** It is one expression inserted ahead of each ordering
  branch rather than a second query path with its own paging semantics.

The bucket has to be an aggregate, because the ranked query groups by
`source_video_id`:

```sql
CASE WHEN max(di.seen_at) < :seen_before
      AND max(di.seen_at) > :seen_since THEN 1 ELSE 0 END
```

A cook has at most one impression row per source, so `max()` of a one-row group
is that row; a source never served aggregates to `NULL`, falls through to `0`,
and leads. The join is `LEFT OUTER` with the cook in the **ON** clause — in the
`WHERE` it silently degrades to an inner join and the feed loses every source
the cook has not seen, which is the exact opposite of the intent.

## One parameter governs both halves

`seen_before` is the moment the client began this paging session. It decides
both what is demoted and whether anything is recorded, and that coupling is
deliberate rather than economical: a caller that is not paging a feed is not
building a reading position either.

| Caller | Sends `seen_before` | Effect |
|---|---|---|
| Discover list, page 1 (`load()`) | yes, a fresh `Date()` | demotes the last session, records this page |
| Discover list, `loadMore()` | yes, the **same** stamp | pages stay put, records this page |
| Pull to refresh | yes, a new stamp | the previous session's rows sink |
| "New to Overeasy" / "Quick dinners" | no | rails stay rankings |
| Watch | no | its feed stays deterministic |

### Why the pin makes paging safe

The cursor is an offset. Without a pin, page 1 writes impressions, page 2
re-ranks against them, and the reader gets a row they already saw while two
they never reached are skipped. Because impressions are stamped at request
time they are always *newer* than `seen_before`, so `seen_at < seen_before` is
false for everything this session wrote. The failure mode is asserted directly
rather than described:
`test_discover_paging_is_pinned_to_the_session_that_started_it` walks three
pages under one pin and gets each row exactly once, then repeats the first two
pages with the pin renewed between them and gets `["Smash Burgers", "Lemon
Orzo"]` back for page 2 — a repeat and two skips.

### Rails and Watch

A shelf is a ranking, not a reading position. "New to Overeasy" that hid what
is new because the cook glanced at it would stop meaning what its title says,
and a rail reordered by the list underneath it would be incoherent. Watch
shares `DiscoverViewModel` but is a different surface — a video swiped past
there is not a row read in the list — and its feed must be identical on every
launch or the UI tests stop meaning anything. Both get the same answer for
free by simply not sending the parameter. `DiscoverViewModel` grew a
`recordsSeenSources` flag beside the `loadsShelves` one it already had; Watch
passes `false`.

The issue brief anticipated Watch recording impressions and called it
acceptable. It does not, and that is a deliberate improvement: the flag is one
line and the alternative demotes sources on a screen the cook never reached
them from.

## Decay, merge, deletion

- **Decay** is the retention sweep: `RetentionPolicy.discover_impression_days`
  (30). The demotion window is `Settings.discover_seen_window_hours` (24), so a
  row stops affecting the feed long before it is erased — the sweep is what
  stops the *record* outliving its purpose, not what limits the suppression.
- **Merge** cannot re-point rows the way `Recipe`, `ImportJob` and `Device` are
  re-pointed: `(user_id, source_video_id)` is the primary key and both accounts
  may hold a row for the same source. `_merge_discover_impressions` upserts
  with `greatest(existing, incoming)` and then deletes the guest's, so signing
  in neither resurrects a source already scrolled past nor loses the position
  the cook was reading from.
- **Deletion** is the FK cascade, like every other per-user table. The
  migration test deletes the `users` row and asserts the impressions go with
  it.

## Choices the brief left open, and one it settled

- **What counts as seen: served**, the brief's stated default. Client-reported
  impressions via `.onAppear` would be more accurate — a 30-row page shows
  about five — but they need a new endpoint, a new rate-limit policy and a
  batching path on the client. Demotion rather than exclusion also blunts the
  cost of over-counting: a good row the cook scrolled past sinks, it does not
  vanish. Worth revisiting once there is real usage.
- **Window 24 hours, retention 30 days**, both `Settings` fields, neither worth
  agonising over before real usage.
- **The window edge is not pinned.** Demotion compares against `now - window`,
  not `seen_before - window`, as the brief specified. A paging session that ran
  longer than the window could therefore see a source cross out of the bucket
  mid-walk and move. Sessions last minutes and the window is a day, so this is
  theoretical; pinning it to `seen_before` would remove even that, and is the
  obvious change if it ever matters.
- **Naive timestamps are read as UTC.** `seen_at` is `timestamptz`; a client
  that dropped the offset would otherwise have its pin interpreted in the
  database session's zone and shift the window by hours. The app sends `Z`.

## Migration

`0022_record_which_discover_sources_a_cook_has_seen`, `down_revision = "0021"`,
and `DatabaseReadinessProbe.expected_revision` moves to `"0022"`.

```
discover_impressions
  user_id         uuid  PK  FK users(id)         ON DELETE CASCADE
  source_video_id uuid  PK  FK source_videos(id) ON DELETE CASCADE
  seen_at         timestamptz NOT NULL
  ix_discover_impressions_user_seen_at (user_id, seen_at)
```

`seen_at` is overwritten by `ON CONFLICT DO UPDATE` rather than appended, so
the table is bounded by corpus size per cook rather than by how often they
scroll. The `(user_id, seen_at)` index serves the retention sweep; the primary
key already serves the feed's join.

The migration ships with the next `Backend/deploy/vps/push.sh`; nothing was
run against production from this branch.

## No wire change beyond one query parameter

`DiscoverPageDTO` is untouched, so `Contracts/Fixtures/*.json`,
`Backend/tests/contracts/` and `RemoteContractTests` are unchanged — the same
situation as #50. The route inventory, the schema section and the
`openapi.py` description map are updated.

## Privacy

This is the first per-user behavioural record the server keeps, and it is
disclosed as one. `docs/privacy-policy.md` gains a "Data we collect and why"
bullet, a retention line and a mention in the deletion list;
`PrivacyDetailView.Copy.storedDataItems` gains the matching plain-language
item. Both say what is *not* stored — no dwell time, no opens, nothing about
what the cook did next — because the honest boundary is the point.

## Affected components

- `Backend/alembic/versions/0022_record_which_discover_sources_a_cook_has_seen.py`
- `Backend/ladle/db/models.py` — `DiscoverImpression`
- `Backend/ladle/recipes/repository.py` — the bucket, the outer join, the upsert
- `Backend/ladle/recipes/service.py` — `now`, the window, the write
- `Backend/ladle/api/routes/recipes.py` — `seen_before`, and the transaction
  the handler did not have
- `Backend/ladle/config.py`, `Backend/ladle/api/app.py`,
  `Backend/ladle/worker/runtime.py`
- `Backend/ladle/privacy/retention.py`, `Backend/ladle/auth/merge.py`
- `Backend/ladle/api/routes/health.py`, `Backend/ladle/api/openapi.py`
- `Ladle/Remote/DiscoverService.swift`, `Ladle/Library/DiscoverView.swift`,
  `Ladle/Library/WatchView.swift`, `Ladle/Account/PrivacyDetailView.swift`
- `Backend/docs/integration-reference.md`, `docs/privacy-policy.md`

## Verification on 2026-09-01

Backend, from `Backend/`:

- `uv run pytest tests/api/test_discover_paging.py -q` — 7 passed. The three
  new tests were written first and failed before the repository change.
- `uv run pytest tests/integration/auth/test_merge.py -q` — 9 passed.
- `uv run pytest tests/integration/privacy/test_retention.py tests/integration/imports/test_quotas.py -q`
  — 6 passed.
- `uv run pytest tests/integration/test_migrations.py -q` — 9 passed,
  including `test_migrated_schema_matches_model_metadata` (`alembic check`).
- `uv run pytest tests/api tests/integration tests/unit -q` —
  **797 passed, 1 warning in 69.40s**.
- `uv run ruff format --check .`, `uv run ruff check .`,
  `uv run mypy --strict ladle` — identical to the `origin/main` baseline
  captured before any edit: one unformatted file
  (`alembic/versions/0019_*.py`), two `I001` findings (`0020_*.py`,
  `0021_*.py`), five mypy errors in `ladle/acquisition/provider_chain.py` and
  `ladle/worker/runtime.py`. No new findings.

Client, under the watchdog (the process prints its results and never exits;
`** BUILD INTERRUPTED **` at the end of the log is the watchdog):

- `-only-testing:LadleTests` —
  **Executed 394 tests, with 1 test skipped and 0 failures**.
  The pin test was confirmed non-vacuous by temporarily replacing
  `seenBefore: sessionStartedAt` in `loadMore()` with a fresh `Date()`:
  `testLoadMoreReusesTheTimestampTheSessionStartedWith` failed with
  `("3") is not equal to ("1")`, then passed again once restored.
- `-only-testing:LadleUITests/DiscoverInteractionUITests` plus
  `StateScenarioUITests/testDiscoverEmptyScenario`,
  `testDiscoverRateLimitedScenario`,
  `testDiscoverFailureOnLaunchFallsBackToRecipes`, `testLaunchLandsOnDiscover`
  — all passed.

Local stack, rebuilt with `docker compose up -d --build api worker` so the
worker picked up the new `RetentionPolicy` field:

- `alembic_version` is `0022`; `\d discover_impressions` shows the composite
  primary key, `ix_discover_impressions_user_seen_at`, and both
  `ON DELETE CASCADE` foreign keys.
- `GET /health/ready` → `{"status":"ready", …}` with every check ready, which
  is the readiness probe agreeing on `"0022"`.
- With a fresh guest token, `?limit=3&seen_before=T0` returned Chicken
  Piccata Pasta, Red Thai Curry Shrimp Mince and Creamy Garlic-Lemon
  Chickpeas, and exactly those three rows appeared in `discover_impressions`
  stamped at the request.
- Two seconds later, `?limit=20&seen_before=T1` returned the same eight
  sources with those three moved from positions 0–2 to positions 5–7 —
  demoted, not dropped.
- The control request with no `seen_before` returned them at 0–2 again:
  nothing demoted, nothing recorded.

The stack was left running and healthy: `api` and `worker` healthy after the
rebuild, `beat`, `postgres`, `redis`, `minio` and `device-edge` untouched and
still up.
