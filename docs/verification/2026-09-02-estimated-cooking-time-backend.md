# Estimated cooking time — backend

Issue #64, backend half. The iOS half (rendering "About 25 min" and its
reason) is a separate change; nothing here touches `Ladle/`.

## Purpose

Most recipes open with "— Total time". On the production copy of the library
(28 live recipes, 2026-09-02) six carry a total, eight a cooking time, three a
preparation time; ten of the 22 with no total carry step timers summing 10–65
minutes. That is not a rendering bug: the extraction prompt told the model to
leave every minute field null unless the creator stated a time, and creators
rarely state one.

PRODUCT.md already settles what to do: "conservative amounts may be inferred
when the dish and standard technique support them, but every estimate is
labeled inline." Servings has worked that way for months. Time now does too.

## Behaviour

**Extraction.** `RecipeExtraction` gains `time_basis`
(`stated` / `estimated` / `unknown`), mirroring `servings_basis`. The prompt
prefers stated times; where none is stated it asks for a conservative
`totalMinutes` from the method and the step timers with `timeBasis` set to
`estimated`. `preparationMinutes` and `cookingMinutes` stay null when unstated —
they are claims about how the work divides, and there is no basis for them.
`PROMPT_VERSION` is now `recipe-2026-09-02-v14`.

**Labelling.** `build_reviewed_template` appends a `total_minutes`
uncertainty — "Total time was estimated from the method; the creator did not
state one." — and never adds it to `blocking`. The recipe stays `ready`.

**Verification.** The total < prep + cook rule stays (it is what caught the
"10-Minute Chili Garlic Noodles" case, where the title's number was written
over stated prep 10 + cook 20). One rule is added: an *estimated* total below
the sum of the recipe's own step timers is an issue, with `_time_text`
evidence.

**Discover.** The "Quick dinners" shelf compared `min(Recipe.total_minutes)`,
so a source whose savers state only a cooking time aggregated to NULL and
dropped out. It now compares
`coalesce(total, prep + cook, cook, prep)`. A source nobody timed at all is
still absent, never assumed fast.

**Backfill.** `python -m ladle.admin.backfill_times [--dry-run] [--limit N]`
gives the recipes already in the library the estimate the new prompt would
have given them — the extraction cache is keyed on the prompt version, so
without it they keep their "—" until every source is re-imported.

## Decisions

- **An uncertainty, not a new column.** The estimate travels as an ordinary
  `FieldUncertaintyDTO` on `total_minutes`. Nothing new on the wire, so no
  migration and no `expected_revision` bump, and the app reuses the rendering
  path it already has for the servings estimate. `time_basis` lives on the
  extraction model only; storing it would be a column, a migration and a
  second source of truth for the same fact.
- **Labelled never blocks; impossible does.** A plain estimate is a caveat and
  keeps the recipe `ready` — an estimate says nothing about whether the rest of
  the recipe can be cooked from. An estimate *below the recipe's own step
  timers* is different: it is not conservative, it is wrong, so it goes through
  verification like any other defect and, if the model cannot repair it from
  the evidence, `_with_issues` sends that recipe to review. Worth knowing when
  reading "never blocking review": the label alone never blocks, a
  self-contradicting number can.
- **The floor is the timer sum, not a ratio.** `max(timer minutes, stated prep
  + cook)`. A *stated* total is deliberately exempt: steps overlap, and a
  creator is allowed to say 20 minutes over 65 minutes of timers. An estimate
  we made is not.
- **Numbers in titles are totals.** "10-Minute …" is a claim about the whole
  dish, never a prep or cook time, and it yields to durations stated in the
  steps. Both the prompt and a verification test pin this.
- **The backfill writes through the edit path.** `RecipeService.upsert` with
  the row's current revision, not a column update: the phone pages
  `recipe_changes` from its cursor, so a row changed in place would never
  arrive. `review_status` is carried through untouched, recipes that already
  carry a total are skipped (so re-running is safe), and a `SyncConflict` is
  reported as a skip rather than overwriting a cook's edit.
- **The backfill goes through the worker's provider abstraction.** Not
  `RecipeExtractor` — that re-extracts a whole recipe from an acquisition
  context. The narrow question is modelled on the verification clients:
  `TimeEstimate` with strict structured output, an
  `OpenRouterTimeEstimateClient` and an `AnthropicTimeEstimateClient` chosen by
  `settings.extraction_provider`, exactly as `_recipe_verifier` chooses. The
  provider sees title, caption, ingredients and ordered steps with timers —
  no transcript, no images, no nutrition.

## Affected files

Backend

- `ladle/extraction/models.py` — `TimeBasis`, `RecipeExtraction.time_basis`
- `ladle/extraction/prompt.py` — TIMING rules, method-bridging carve-out,
  `PROMPT_VERSION`
- `ladle/extraction/review.py` — `ESTIMATED_TOTAL_REASON`, the non-blocking
  uncertainty
- `ladle/extraction/verification.py` — `_timer_minutes`, the estimated-total
  floor rule
- `ladle/recipes/repository.py` — the Discover coalesce
- `ladle/admin/backfill_times.py` — new
- `deploy/vps/manage.sh` — `backfill-times`
- `docs/integration-reference.md` — new "Admin commands" section;
  `docs/deployment/vps.md`

Contracts and tests

- `Contracts/Fixtures/recipe-estimated-time.json` — new
- `tests/contracts/test_golden_fixtures.py`,
  `Packages/LadleCore/Tests/LadleCoreTests/RemoteContractTests.swift`
- `tests/unit/extraction/{test_review,test_verification,test_prompt}.py`
- `tests/api/test_discover_paging.py`
- `tests/integration/admin/test_backfill_times.py` — new
- `tests/unit/deploy/test_vps_simplified_profile.py`

## Verification

- `uv run pytest` from `Backend/` — **855 passed**.
- `uv run ruff format --check .` — 329 files already formatted.
- `uv run ruff check .` — all checks passed.
- `uv run mypy --strict ladle` — no issues in 123 source files.
- `swift test --package-path Packages/LadleCore` — 48 tests in 9 suites passed.

Tests written failing first, one per part: the estimate uncertainty and its
non-blocking status; the timer-sum rule, the estimated-total pass, the
stated-total exemption and the Chili Garlic Noodles title case; the cook-only
source qualifying for the 30-minute shelf; the fixture round-trip; and five
backfill cases — dry run writes nothing, a real run bumps the revision and
labels the estimate, a second run is a no-op, an estimate under the timer sum
is refused, and **a backfilled recipe arrives in the sync page a device would
fetch**.

### Dry run against the production copy

`ladle_nutrition_scratch` on the local Compose Postgres, live OpenRouter
provider, 2026-09-02. Nothing was written; the database still reads 28 live /
22 without a total afterwards.

```text
recipe                             creator              prep  cook    timers  proposed  action
---------------------------------  -------------------  ----  ------  ------  --------  -----------------------------
Stuffed bell peppers               jose.elcook          —     —       —       35 min    would set 35 min
Stuffed bell peppers               jose.elcook          —     —       —       30 min    would set 30 min
Unknown Recipe                     jose.elcook          —     —       —       —         skipped: no estimate returned
Stuffed Bell Peppers               jose.elcook          —     —       15 min  40 min    would set 40 min
Stuffed bell peppers               jose.elcook          —     —       —       35 min    would set 35 min
Stuffed Bell Peppers               jose.elcook          —     —       15 min  40 min    would set 40 min
Spicy Tofu & Chicken Noodles       finntonry            —     —       —       25 min    would set 25 min
High-Fiber Cilantro Lime Rice      Liam                 —     —       —       10 min    would set 10 min
Fiber-Rich Cilantro Lime Rice      Liam                 —     —       —       10 min    would set 10 min
Creamy Italian Sausage Rigatoni    Stealth Health Life  —     —       22 min  50 min    would set 50 min
Fiber-Rich Cilantro Lime Rice      Liam                 —     —       —       10 min    would set 10 min
Gobi Manchurian                    brin.pirathapan      —     —       —       30 min    would set 30 min
Egg Bhurji                         The Golden Balance   —     —       —       20 min    would set 20 min
Creamy Italian Sausage Rigatoni    Stealth Health Life  —     —       22 min  50 min    would set 50 min
Madras Curry                       izhecoconuts         —     —       —       45 min    would set 45 min
One Pot Creamy French Onion Pasta  Zach 👨🏻‍🍳            —     —       10 min  45 min    would set 45 min
Single-Serving Shakshuka           Sara                 —     23 min  23 min  30 min    would set 30 min
Lasagna Soup                       Itsemilyrangel       —     30 min  25 min  45 min    would set 45 min
The Best Vegan Pizza!              dr.vegan             —     30 min  65 min  80 min    would set 80 min
Shaved Tofu Wrap                   Lily Baker           —     —       25 min  40 min    would set 40 min
Madras Curry                       izhecoconuts         —     —       —       40 min    would set 40 min
Lasagna Soup                       Itsemilyrangel       —     —       25 min  45 min    would set 45 min

22 recipes considered, 0 written (dry run).
```

Every estimate clears its own floor: Vegan Pizza's 65 timer-minutes and 30
stated cook minutes produce 80, Shakshuka's 23 produce 30. One recipe
("Unknown Recipe", a failed import with nothing to reason from) returned no
estimate and was skipped rather than guessed at.

## Running the backfill on the VPS

After this merges and deploys:

```bash
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh backfill-times --dry-run
sudo /opt/ladle/app/Backend/deploy/vps/manage.sh backfill-times
```

`push.sh` ships `manage.sh` with the revision, so the command exists on the
VPS as soon as the deploy lands. The dry run costs one provider call per
recipe (~22) and writes nothing; read the table before the real run.

## Addendum, 2026-09-02 — retrying and pacing the backfill

### Production symptom

The first production dry run (`manage.sh backfill-times --dry-run`, deployed at
`f7b0227`, live OpenRouter) estimated the first 13 recipes and then reported
`skipped: no estimate returned` for all 9 remaining — Madras Curry, the
Shakshuka, both Lasagna Soups and the Vegan Pizza among them, every one of
which had estimated fine in the local run the day before.

That pattern — a clean prefix, then a uniform tail — is a rate limiter, not
nine models declining at once. `OpenRouterTimeEstimateClient.estimate`
returned `None` on any `httpx.HTTPError` and on any status ≥ 400, with no
retry and nothing recorded about which it was, so a 429 after a burst of
22 back-to-back requests was indistinguishable from a refusal. The extraction
client had already met and solved this (`extraction/openrouter.py`); the
backfill client had not inherited it.

### Fix

- **Retry.** Both estimate clients now make up to 3 attempts, retrying 429,
  5xx and transient `httpx.HTTPError`, honouring the server's `Retry-After`
  and otherwise backing off exponentially (2s, 4s). Other 4xx are not
  retried — a request this provider rejects outright will be rejected the
  next two times too. `_retry_after_seconds` was promoted to
  `retry_after_seconds` in `extraction/openrouter.py` and is now shared, so
  the header parsing and its 60-second bound have one implementation. It
  takes the header value rather than a response object: the Anthropic SDK
  carries its response on the exception, and that response comes from a
  different httpx distribution (`httpx2`) than the one this project uses.
  The SDK's own `max_retries` is set to 0 in `build_service`, so the loop
  here is the single retry policy rather than one stacked on another —
  otherwise a persistent 429 would cost nine requests, not three.
- **Pacing.** `TimeBackfillService` waits one second between recipes (not
  before the first). A 22-row run costs an extra 21 seconds and stops
  arriving as a burst.
- **Reasons.** `estimate` returns an `EstimateOutcome` — an estimate, or the
  reason there is none — and the reason reaches the `action` column verbatim:

  | action | means |
  | --- | --- |
  | `skipped: provider 429 after 3 attempts` | rate limited, retries exhausted; re-run the command |
  | `skipped: provider 502` | upstream error, retries exhausted |
  | `skipped: provider 400` | request rejected, not retried |
  | `skipped: request failed (ConnectTimeout)` | transport failure, retries exhausted |
  | `skipped: no estimate in reply` | the provider answered, with nothing usable in it |
  | `skipped: below timer sum (65 min)` | the estimate was under the floor |

  `set N min` and `would set N min` are unchanged. The floor line names which
  bound it broke — `below timer sum (N min)` or `below stated prep + cook
  (N min)` — because "timer sum" would be a lie on a recipe with no timers.

Retries are logged at WARNING in both clients, so a run that recovers still
leaves a trace of what it recovered from.

One adjacent bug fixed while here: a 200 whose `content` is null — what a
content filter returns — reached the unfencing helper as `None` and raised
`AttributeError`, which is outside the handled tuple. That would have aborted
the run and rolled back every estimate before it. It now reads as
"no estimate in reply".

### Verification

- `uv run pytest` from `Backend/` — **869 passed** (was 855; 12 new client
  unit tests and 2 new backfill integration tests).
- `uv run ruff format --check .`, `uv run ruff check .`,
  `uv run mypy --strict ladle` — all clean.

New unit tests in `tests/unit/admin/test_backfill_times_client.py` drive an
`httpx.MockTransport`: two 429s with `Retry-After: 0` then a 200 still yields
an estimate; a persistent 429 exhausts and names itself; 5xx retries then
names the status; 400 is not retried; a transport error names its exception
class; and both a `choices: []` body and a `finish_reason: length` reply read
as "no estimate in reply" rather than a provider failure, as does a null
`content`. Two more drive the Anthropic client through a real
`anthropic.RateLimitError` to prove it honours `Retry-After` and names an
exhausted rate limit. Two integration tests cover the reason reaching the
table and the pause falling between recipes rather than before the first.

The unit file is named `test_backfill_times_client.py` rather than
`test_backfill_times.py`: the test tree has no `__init__.py` files, so pytest
requires unique module basenames and the integration file already owns that
name.
