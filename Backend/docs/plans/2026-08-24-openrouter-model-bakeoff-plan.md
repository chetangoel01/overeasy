# OpenRouter Recipe Extraction Bake-Off Implementation Plan

> **Execution note:** Follow this plan task by task with red-green-refactor and
> commit each verified coherent change on `codex/extraction-accuracy`.

**Goal:** Measure five lower-cost OpenRouter models against Claude Opus 5 on
Ladle's frozen text-only recipe corpus and produce a reproducible quality-first
recommendation.

**Architecture:** Extend the existing production-path evaluator with explicit
model selection and complete per-case benchmark measurements. Keep comparison
and ranking pure in `ladle.evaluation` so unit tests can validate compatibility,
aggregation, quality gates, finalist selection, and price tie-breaking without
network calls. A thin script reads immutable result JSON and writes the ranked
comparison artifact.

**Tech stack:** Python 3.12, Pydantic, httpx, pytest, Ruff, mypy, OpenRouter's
OpenAI-compatible structured-output API, and the existing USDA integration.

---

## Task 1: Add evaluator model and measurement seams

**Files:**

- Modify: `Backend/scripts/eval_extraction.py`
- Create: `Backend/tests/unit/scripts/test_eval_extraction.py`

### Step 1: Write failing tests

Load the evaluator script as a module and add narrow tests proving:

- `--model` is accepted and passed to both extraction and verification;
- a requested model overrides settings without changing the production default;
- nearest-rank p95 and median latency summaries are deterministic;
- an existing result label is rejected rather than overwritten;
- verification usage is captured when a targeted verification call occurs and
  remains zero when no verifier call is needed.

### Step 2: Run the narrow tests and confirm red

Run:

```bash
cd Backend
uv run pytest tests/unit/scripts/test_eval_extraction.py -q
```

Expected: failures for the missing model override and benchmark measurements.

### Step 3: Implement the minimum evaluator changes

In `Backend/scripts/eval_extraction.py`:

- add `--model` and thread the pinned ID through `_pipeline`;
- wrap the verification client with an in-memory recorder for input tokens,
  output tokens, and reported cost;
- measure end-to-end elapsed milliseconds with `time.perf_counter`;
- record UTC run time, per-case latency, extraction and verification usage;
- add aggregate valid-output, structural micro-recall, latency, token, and cost
  fields;
- refuse to overwrite an existing result artifact;
- keep API keys environment-only and avoid logging response bodies.

### Step 4: Run tests and refactor

Run:

```bash
cd Backend
uv run pytest tests/unit/scripts/test_eval_extraction.py -q
uv run ruff check scripts/eval_extraction.py tests/unit/scripts/test_eval_extraction.py
uv run mypy scripts/eval_extraction.py
```

Expected: all pass.

### Step 5: Commit

```bash
git add Backend/scripts/eval_extraction.py Backend/tests/unit/scripts/test_eval_extraction.py
git diff --check
git commit -m "feat: measure model extraction bake-offs"
```

## Task 2: Add pure model-run comparison and ranking

**Files:**

- Create: `Backend/ladle/evaluation/model_comparison.py`
- Create: `Backend/scripts/compare_extraction_models.py`
- Create: `Backend/tests/unit/evaluation/test_model_comparison.py`

### Step 1: Write failing comparison tests

Cover:

- rejecting runs whose corpus digest, fixture version, prompt version, partition,
  or case count differ;
- aggregating successful-output, nutrition, ingredient-pair, ordered-phrase,
  cook-time, cost, latency, and visual-call measurements;
- requiring every run for an eligible model to pass the hard gates;
- grouping repeat runs by pinned model ID and reporting metric ranges;
- selecting the strict quality leader before considering price;
- treating models within one percentage point on all structural metrics and with
  the same structured-output rate as comparable;
- choosing lower complete reported cost, then median and p95 latency, only within
  that comparable-quality group;
- excluding incomplete cost evidence from a price-based recommendation.

### Step 2: Run and confirm red

Run:

```bash
cd Backend
uv run pytest tests/unit/evaluation/test_model_comparison.py -q
```

Expected: import failure because the comparison module does not exist.

### Step 3: Implement comparison module and script

Use Pydantic result models for validated JSON input and output. Keep aggregation
and winner selection free of filesystem and network access. The script should:

- accept two or more result paths and a required output label;
- validate run compatibility before ranking;
- write under `Backend/.eval-cache/results/` without overwriting;
- print a compact table with model, run count, gate status, valid output,
  nutrition, ingredient recall, step recall, cook-time accuracy, cost, p50, and
  p95;
- identify the quality leader, comparable-quality set, and value winner.

### Step 4: Verify and commit

Run:

```bash
cd Backend
uv run pytest tests/unit/evaluation/test_model_comparison.py -q
uv run ruff check ladle/evaluation/model_comparison.py scripts/compare_extraction_models.py tests/unit/evaluation/test_model_comparison.py
uv run mypy ladle/evaluation/model_comparison.py scripts/compare_extraction_models.py
git diff --check
```

Then commit:

```bash
git add Backend/ladle/evaluation/model_comparison.py Backend/scripts/compare_extraction_models.py Backend/tests/unit/evaluation/test_model_comparison.py
git commit -m "feat: rank recipe extraction models"
```

## Task 3: Regression verification before live spend

**Files:**

- Modify if needed: `Backend/docs/plans/2026-08-24-openrouter-model-bakeoff-design.md`

### Step 1: Run affected and full backend checks

Run:

```bash
cd Backend
uv run pytest tests/unit/evaluation tests/unit/extraction tests/unit/scripts -q
uv run pytest -q
uv run ruff check .
uv run mypy ladle
git diff --check
```

Expected: all tests and static checks pass.

### Step 2: Confirm branch checkpoint

Run `git status --short --branch`. Commit only any necessary documentation
correction; otherwise leave the verified branch clean.

## Task 4: Run one-case live preflights

**Artifacts:**

- Create: `Backend/.eval-cache/results/2026-08-24-bakeoff-preflight-*.json`

### Step 1: Inject secrets ephemerally

Read the OpenRouter and USDA keys into a PTY without echo, export them only for
the child process, and never write them to shell history, files, output, or Git.

### Step 2: Run one representative held-out case per candidate

Invoke `scripts/eval_extraction.py extract` with a unique label, `--corpus
held-out`, `--only` targeting the same recipe, and each pinned `--model` ID.

Expected for every model: HTTP success, schema-valid extraction, correct pinned
model in the artifact, recorded latency/usage/cost, and zero visual calls.

### Step 3: Stop on protocol incompatibility

If a candidate fails structured output, confirm the failure on one new labeled
attempt. Do not tune its prompt or provider routing. Record a confirmed protocol
failure as benchmark evidence and continue with the remaining candidates.

## Task 5: Run the exhaustive first pass

**Artifacts:**

- Create: six uniquely labeled held-out result JSON files in
  `Backend/.eval-cache/results/`
- Create: `Backend/.eval-cache/results/2026-08-24-bakeoff-round1-comparison.json`

### Step 1: Run all six pinned candidates

Run the complete held-out corpus sequentially for:

1. `deepseek/deepseek-v4-pro-0813`
2. `moonshotai/kimi-k3`
3. `google/gemini-3.7-flash`
4. `x-ai/grok-4.6`
5. `qwen/qwen3-235b-a22b-2507`
6. `anthropic/claude-opus-5`

Keep each run's console output available until its artifact is validated. Do not
parallelize live calls because shared upstream rate limits could bias reliability
and latency.

The runner prints and flushes the model ID, case key, and `[current/total]`
position before each request. This makes long provider stalls distinguishable
from normal sequential progress without changing benchmark inputs or scoring.

### Step 2: Validate and compare round one

Run the comparison script over the six artifacts. Confirm compatible corpus and
prompt identities, 80 scored cases per run, 20 sparse cases, and zero visual
calls. Inspect every provider/schema error and the aggregate raw totals.

## Task 6: Repeat finalists and determine the recommendation

**Artifacts:**

- Create: second-run JSON for the top two non-Opus candidates and Opus
- Create: `Backend/.eval-cache/results/2026-08-24-bakeoff-final-comparison.json`

### Step 1: Repeat the quality finalists

Repeat the two highest-quality passing non-Opus models and Claude Opus 5 with new
labels and unchanged settings.

### Step 2: Produce final comparison

Compare the original and repeat artifacts. Require every run of a recommended
model to pass the hard gates. Select the strict quality leader, then the cheaper
value winner only if it is within the approved one-percentage-point quality
equivalence band.

### Step 3: Sanity-check reported cost

Cross-check total reported cost against the sum of all per-case extraction and
verification costs. If any provider omits cost, mark price evidence incomplete
and estimate separately from the pinned catalog prices without presenting that
estimate as measured spend.

## Task 7: Document and verify the measured result

**Files:**

- Create: `Backend/docs/verification/2026-08-24-openrouter-model-bakeoff.md`
- Modify: `Backend/docs/plans/2026-08-24-openrouter-model-bakeoff-design.md`
  only if the executed protocol required an approved correction

### Step 1: Write the verification report

Record purpose, exact model IDs, frozen protocol, hard gates, per-model metrics,
failure analysis, repeatability, measured/estimated cost distinction, quality
leader, comparable-quality models, recommended production candidate, and the
fallback model. Link the immutable local result artifacts by filename.

### Step 2: Final verification

Run:

```bash
cd Backend
uv run pytest -q
uv run ruff check .
uv run mypy ladle
git diff --check
```

Expected: all checks pass.

### Step 3: Commit the report

```bash
git add Backend/docs/verification/2026-08-24-openrouter-model-bakeoff.md
git diff --check
git commit -m "docs: record OpenRouter model bake-off"
```

Result JSON remains ignored benchmark evidence unless repository policy already
tracks `.eval-cache`; do not force-add secrets, caches, or generated artifacts.
