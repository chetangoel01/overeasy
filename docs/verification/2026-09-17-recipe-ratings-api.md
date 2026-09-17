# Source engagement and star ratings — API

Date: September 17, 2026
Issue: [#143](https://github.com/chetangoel01/overeasy/issues/143)
Branch: `codex/feedback-143-ratings-api`, stacked on
`codex/feedback-resolution-2026-09-17`.
Status: **backend built and verified. The iOS surfaces are not built** — they
wait on the layout review, and nothing in the app reads these fields yet.

## Purpose

#143 asked whether cooks could judge a recipe by clearer counts and by
feedback from people who made it. The owner chose the first version on
September 17: **the counts that already exist, plus 1–5 star ratings. No
written reviews.** Counts must say what they measure, and one that is unknown
must never read as zero.

## Behaviour

- `GET /v1/recipes/discover/{sourceVideoID}/engagement` →
  `SourceEngagementDTO`: `savedCount` (Overeasy accounts holding a live copy,
  the caller included), `likeCount` (the source platform's snapshot from
  import, or null), `ratingCount`, `ratingAverage`, and `myRating`.
- `PUT .../rating` with `{"stars": 1..5}` sets or changes the caller's rating;
  `DELETE .../rating` clears it and is idempotent. Both answer with the
  engagement as it stands afterwards.
- Every Discover item — feed and shelves — gains `ratingAverage` and
  `ratingCount`. There is no new sort.
- `RecipeDTO` gains `sourceID`, so a saved recipe can ask for its source's
  engagement. Null for a recipe typed in by hand; a Discover preview carries
  the source it previews. Set by the server and ignored on `PUT`.
- Errors: stars outside 1–5 → `422`; rating without a live saved copy → `409`
  `conflict`, the convention `ImportRetryUnavailable` and `AccountMergeInvalid`
  already follow (a new error code would fail to decode in shipped builds, and
  `403` is mapped to `authenticationRequired`); unknown source → `404`. Unlike
  the preview route, these need only the source row, not a ready shared
  extraction: a saved recipe whose source went stale can still be rated.
- Rate limits: the read shares `sync:user` with the other Discover reads, the
  writes share `recipe-mutation:user` with saving.

Wire shapes are pinned by `Contracts/Fixtures/source-engagement.json`,
`discover-page.json` and `discover-shelves.json`.

## Decisions

Owner's:

1. First version is existing counts plus star ratings; no written reviews.

Engineering calls, made on the owner's behalf and open to reversal:

2. A rating belongs to the shared source (`source_videos`), not to a cook's
   copy: one average per video, and private edits stay private.
3. One rating per account per source, whole stars, changeable and clearable.
4. Only an account holding an undeleted saved recipe from the source may
   rate, guests included. Clearing is never gated.
5. The average is published once `LADLE_RATING_MINIMUM_COUNT` accounts
   (default 3) have rated; below that it is null while the count is served.
   Rounded to one decimal, in SQL.
6. Aggregates only. Nothing serves who rated what; `myRating` is the caller's.
7. Ratings are the cook's own content: the retention sweep leaves them alone,
   and account deletion removes them through the `users` cascade.
8. A guest merge carries ratings over; where both accounts rated a source the
   later `updated_at` wins, not the higher score.
9. **A rating outlives the saved copy.** Deleting a recipe does not remove the
   rating already given, and it keeps counting. Dropping it would quietly
   remove the cooks most likely to have rated low. The author can still clear
   it. Not asked for either way — flagged for the owner.
10. The threshold lives on `RecipeRepository` rather than being passed per
    call, so the feed, the shelves and the engagement read cannot disagree
    about when an average is published.
11. Ratings are aggregated for the served page in one grouped query, outside
    the ranking query: nothing sorts on them, and joining raters onto a query
    grouped over savers would multiply the rows it counts.

## Affected components

- `Backend/alembic/versions/0027_let_a_cook_rate_a_source_they_saved.py`,
  `ladle/db/models.py` (`RecipeRating`), `ladle/api/routes/health.py`
  (readiness now expects `0027`)
- `ladle/contracts/recipes.py`, `ladle/recipes/repository.py`,
  `ladle/recipes/service.py`, `ladle/api/routes/recipes.py`,
  `ladle/api/openapi.py`, `ladle/config.py`, `ladle/api/app.py`
- `ladle/auth/merge.py` (`_merge_ratings`)
- `Contracts/Fixtures/`: `source-engagement.json` (new), the two Discover
  fixtures, and `sourceID` on every fixture that embeds a recipe
- `Backend/docs/integration-reference.md`, `docs/backend-design.md`,
  `docs/privacy-policy.md`

The privacy policy now lists star ratings under what is collected, retention
and account deletion. It states the default minimum of three, so lowering
`LADLE_RATING_MINIMUM_COUNT` in production would contradict it. The effective
date was left alone, as it was for the impression record; that is the owner's
call.

## Verification

The three behaviour tests below were each seen to fail before their
implementation existed; the fixture row is a pin added with the DTO.

- `tests/api/test_recipe_ratings.py` — one lifecycle: rate, average hidden
  below three, average appears (4.3) on the engagement read and in the feed
  for a cook who saved nothing, change, clear twice, `422`, `409` without a
  copy and after deleting one, `404`.
- `tests/integration/auth/test_merge.py` — the later rating wins in both
  directions, including when it is the lower one, and the guest's rows go.
- `tests/integration/test_migrations.py` — 0027's range check, one row per
  pair, account cascade, index and downgrade; model metadata still matches.
- Existing tests extended rather than added: the pinned Discover item, the
  `sourceID` a client cannot claim, the rating route in the rate-limit wiring.
- Backend suite: 1,141 passed (1,137 before). `ruff format --check`,
  `ruff check` and `mypy --strict ladle` clean.
- `swift test --package-path Packages/LadleCore`: 91 passed against the
  updated fixtures, with no Swift change.

Not done: no deployment, no migration run outside throwaway test databases,
and no iOS work.
