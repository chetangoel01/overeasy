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
