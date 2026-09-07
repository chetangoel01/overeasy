# Recipe tags and a filterable Discover feed (backend)

Issue #87, backend half. The iOS filter control is a separate change; nothing
in `Ladle/` or `Packages/` is touched here.

Stacked on `feat/nutrition-skip-what-does-not-match` (#104), which owns
migration `0024`. This one is `0025`.

## Why

TestFlight feedback from Sagrika Sethi: on the Watch tab she scrolled past ten
chicken videos to find one vegetarian recipe, and wanted to be able to say
"only recipes with chicken in them" too. Nothing stored about a recipe said
what it was, so there was nothing for a filter to ask.

The decision comment on #87 settled the shape: three tag families produced by
the extraction LLM at import, filtering done server-side, one filter model
across Recipes, Discover and Watch, and a backfill over the existing corpus so
that a filter never has to hide untagged recipes.

## What a recipe now carries

| Family | Where it lives | Closed? | Filterable? |
| --- | --- | --- | --- |
| `diets` | `recipe_tags` (`family='diet'`) | yes — 5 values | yes, and all listed must hold |
| `cuisines` | `recipe_tags` (`family='cuisine'`) | yes — 15 values | yes, any listed |
| `keywords` | `recipe_tags` (`family='keyword'`) | yes — 25 curated values | yes, any listed |
| `keywordProposals` | `recipe_keyword_proposals` | no — free text | **no**, until promoted |

Both tables are keyed on `(recipe_id, …, value)` and cascade from the recipe,
so account deletion and the retention sweep need no changes, and a guest→account
merge carries tags along because `auth/merge.py` reassigns `Recipe.user_id`
rather than re-inserting the recipe.

Migration `0025`, on top of #104's `0024`.

Proposals get their own table rather than a fourth `family` value so that "not
filterable until promoted" is a property of the schema rather than a rule in
the query: the Discover filter joins `recipe_tags` and cannot reach a proposal
even by mistake. Promoting one means adding it to `RecipeKeyword` and
re-running the backfill.

### The vocabularies

All three live in `Backend/ladle/contracts/tags.py` and nowhere else. The
prompt is rendered from them, the DTO is typed by them, and the query
parameters validate against them, so they cannot drift apart.

**Diet (5).** `vegetarian`, `vegan`, `pescatarian`, `glutenFree`, `dairyFree`.
The test for inclusion is "decidable from the ingredient list alone". Halal,
kosher and low-FODMAP turn on sourcing, certification or quantity, so a model
reading a caption would be guessing — and a cook who filtered on a guess would
be misled about the thing they care most about.

**Cuisine (15).** `american`, `british`, `caribbean`, `chinese`, `french`,
`indian`, `italian`, `japanese`, `korean`, `latinAmerican`, `mediterranean`,
`mexican`, `middleEastern`, `southeastAsian`, `westAfrican`. Deliberately
coarse: Thai and Vietnamese fold into `southeastAsian`, Greek into
`mediterranean`. Fifty near-empty buckets would be worse than fifteen that
each hold something, and a model asked to choose between neighbours picks
inconsistently.

**Keywords (25).** `onePot`, `weeknight`, `mealPrep`, `highProtein`, `budget`,
`comfortFood`, `airFryer`, `slowCooker`, `pressureCooker`, `sheetPan`,
`noCook`, `baking`, `grilling`, `freezerFriendly`, `kidFriendly`, `partyFood`,
`breakfast`, `brunch`, `lunchbox`, `dessert`, `snack`, `sideDish`, `soup`,
`salad`, `pasta`. Each one has to be worth a Discover shelf. No time-based
keyword, because Discover already filters on `maxTotalMinutes` and a
`under30Minutes` tag would be a second, disagreeing answer.

## How a tag gets there

The prompt (`PROMPT_VERSION` `recipe-2026-09-07-v15`) has a TAGS section
rendered from the enums, and a unit test asserts every enum value appears in
`SYSTEM_PROMPT`, so a vocabulary change cannot silently miss the prompt. The
prompt-digest registry in `tests/unit/extraction/test_prompt.py` then forces
the version bump, which is what invalidates the extraction cache.

`RecipeExtraction` folds the answer back onto the vocabulary rather than
rejecting it: an invented cuisine is dropped, because a payload refused over
one stray tag costs the cook every ingredient and every step of a recipe that
was otherwise fine — the same trade the fraction parser in that file already
makes. Keywords arrive as one free-text list and `review.build_reviewed_
template` does the splitting; a model asked to sort its own terms into
"curated" and "mine" moves them back and forth on identical input.

Tags then travel `RecipeTemplate` → `RecipeDTO` → the tag tables, so they
survive `template_clone`, the review/merge path in `_complete_reimport`, and
`save_discovered`.

## The tri-state on the wire

`diets`, `cuisines`, `keywords` and `keywordProposals` are `list | None` on
`RecipeDTO`. The server always sends lists. On the way *in*:

- `null` (or absent) means **leave what is stored**
- `[]` means **clear it**

This is the one thing that is not cosmetic. Build `20260903.1` encodes no tag
keys at all, and the app sends the whole recipe back on every edit — reading
that silence as an empty list would strip a library of its tags one rename at
a time. `repository._replace_tags` therefore writes per family and leaves an
absent family alone. Covered by
`tests/integration/recipes/test_recipe_tags.py`.

## The filter

`GET /v1/recipes/discover` — the Discover list, its shelves, and Watch (Watch
is this endpoint without `seenBefore`). Four new repeatable parameters:

| Parameter | Type | Composition |
| --- | --- | --- |
| `diet` | `DietTag` | **all** listed must hold |
| `cuisine` | `CuisineTag` | **any** listed |
| `keyword` | `RecipeKeyword` | **any** listed |
| `ingredient` | free text, ≤10 terms of ≤100 chars | **all** listed must be present |

Diets narrow because avoiding gluten and meat means dishes that are both.
Cuisine and keyword widen inside their family because picking two shelves
means you want both. Ingredients narrow again: "only recipes with chicken in
them" is a demand, not a preference. The families then AND together.

The conditions are correlated `EXISTS` clauses sitting beside the existing `q`
search, applied to the savers' rows *before* they are grouped by source. So
paging keeps working with a filter applied and the ranking gains no join.
`saved_count` counts the matching copies, which is the same number in practice
because every copy of a source comes from one extraction template.

Ingredient matching is a substring `ILIKE`, the same shape as `q`: "chicken"
has to find "chicken thighs" and "boneless chicken". The cost is that "egg"
also finds "eggplant". A word-boundary regex would fail more often than that
helps, and there is no ingredient vocabulary to match against yet.

An off-vocabulary value is a 422, not a silent match-everything, which would
have read to a cook as an app with nothing in it. That is also what makes a
proposal structurally unfilterable: `?keyword=cookout` is refused by the enum
before any query runs.

## The backfill

`python -m ladle.admin.backfill_tags [--dry-run] [--limit N]`

Re-acquires each stored source and re-runs the whole extraction against it,
because the caption and the transcript are where the evidence lives and
neither is in the stored recipe. Only the tags are written back — a cook's
title, their corrected quantities and their notes are theirs, and replacing
them with a second opinion would be data loss dressed as an improvement. The
write goes through `RecipeService.upsert`, so the revision bumps and the change
reaches the device's next sync page.

- One acquisition per **source**, not per recipe; `--limit` counts sources.
- Idempotent: a recipe whose stored tags already equal the fresh answer is
  reported `unchanged` and not rewritten, so a second run after fixing one
  private video does not push the whole library down every phone's sync feed.
- Providers are built with `NullProviderUsageSink`, because a provider attempt
  is recorded against an import job by foreign key and this run has no job.
  `runtime_acquirer` / `runtime_extractor` were lifted out of
  `runtime_orchestrator` so both callers wire the providers one way.
- Failures are named, not counted: `skipped: PrivateOrDeleted`,
  `skipped: no source video`, `skipped: edited during the run`.

`FakeRuntimeExtractor` now returns tags, so the whole command — and the filter
— can be rehearsed on the local stack for nothing.

## Verification

Docker was running, so the full backend suite is real.

```
cd Backend
uv run ruff check ladle tests            → All checks passed!
uv run ruff format --check ladle tests   → 254 files already formatted
uv run mypy ladle                        → Success: no issues found in 129 source files
uv run pytest                            → 962 passed, 10 warnings in 26.88s
```

Narrow suites, red before the change and green after:

```
uv run pytest tests/contracts/test_tags.py -n0                    → 12 passed
uv run pytest tests/unit/extraction/test_extraction_tags.py -n0   → 7 passed
uv run pytest tests/integration/recipes/test_recipe_tags.py -n0   → 3 passed
uv run pytest tests/api/test_discover_filters.py -n0              → 13 passed
uv run pytest tests/integration/admin/test_backfill_tags.py -n0   → 8 passed
```

### Local stack

`docker compose up -d --build` from `Backend/`, then `/health/ready` reported
every check ready on migration `0025`. 81 recipes across 14 sources were
already stored from earlier local work.

Dry run, one source:

```
$ docker compose run --rm --no-deps --entrypoint /app/.venv/bin/python worker \
    -m ladle.admin.backfill_tags --dry-run --limit 1
Creamy Garlic-Lemon Chickpeas  mishkamakesfood  vegetarian  mediterranean  onePot, weeknight  lemony  would tag
…
11 recipes considered, 0 written (dry run).
Proposed keywords, held out of the filter until promoted: lemony
```

`recipe_tags` was still empty afterwards. Running it for real wrote 11 rows
for the nine savers of that one source; a second run reported
`11 recipes considered, 0 written`. The tags are the fake extractor's fixed
answer, which is what `LADLE_WORKER_PROVIDER_MODE=fake` is for — a live run
has not been made, and must not be made against production from here.

Then through the API as a fresh guest:

```
/v1/recipes/discover?limit=20                    → 8 sources
/v1/recipes/discover?limit=20&diet=vegetarian    → 1  (Creamy Garlic-Lemon Chickpeas)
/v1/recipes/discover?limit=20&ingredient=chickpea → 1  (the same)
/v1/recipes/discover?diet=keto                   → 422
```

## Known gaps

- **The extraction cache is not rewritten.** It is keyed on `PROMPT_VERSION`,
  so existing entries stay on v14. The backfill tags the savers' `Recipe`
  rows, which is what the Discover filter reads, but `save_discovered` and
  `discover_detail` instantiate from the cache template — so a *new* save of
  an already-cached Discover source arrives untagged until that source is
  imported again under v15. Writing the fresh template into the cache is the
  obvious fix, but the backfill's extractor output skips `apply_creator_facts`,
  nutrition enrichment and the verifier, so it would be a worse cache row than
  the one it replaced. Follow-up.
- **The live provider schema is untested here.** `list[DietTag]` adds enums
  and `keywords` adds `maxItems` to the schema handed to `messages.parse`.
  Existing fields already carry `minItems` and numeric bounds through the same
  path, so this is very likely fine, but the test that would prove it is
  `live_provider`-marked and did not run.
- The iOS filter control, the persisted diet preference and the Discover
  shelves built on keywords are all out of scope here.
