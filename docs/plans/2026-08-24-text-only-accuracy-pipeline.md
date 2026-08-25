# Text-Only Accuracy Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build an accuracy-first recipe pipeline that uses only textual evidence, grounds nutrition in creator facts or USDA data, verifies disputed fields, safely refuses unsupported sparse sources, and proves at least 95% held-out whole-recipe nutrition accuracy.

**Architecture:** Remove every production vision route while retaining captions and audio-to-text transcription. Enrich sparse contexts with creator-validated written pages, extract an evidence-bearing recipe, calculate nutrition deterministically, and run a targeted verifier before persistence. Add a versioned evaluator whose held-out gate—not prompt intuition—controls completion.

**Tech Stack:** Python 3.12, FastAPI/Celery, Pydantic, SQLAlchemy/Alembic, PostgreSQL, httpx, OpenRouter structured output and text search, USDA FoodData Central, pytest, Ruff, mypy.

---

Use `@superpowers:test-driven-development` for every production change,
`@superpowers:systematic-debugging` for unexpected failures, and
`@superpowers:verification-before-completion` before each commit or milestone
claim.

### Task 1: Add authoritative evaluation gates

**Files:**
- Create: `Backend/ladle/evaluation/__init__.py`
- Create: `Backend/ladle/evaluation/extraction.py`
- Create: `Backend/tests/unit/evaluation/test_extraction.py`
- Create: `Backend/tests/fixtures/evaluation/text-only-tuning.json`
- Create: `Backend/tests/fixtures/evaluation/text-only-held-out.json`
- Modify: `Backend/scripts/eval_extraction.py`

**Step 1: Write the failing scorer tests**

Define reference and prediction models plus a whole-recipe nutrition result:

```python
class NutritionReference(WireModel):
    servings: Decimal
    calories: Decimal
    protein_grams: Decimal
    carbohydrate_grams: Decimal
    fat_grams: Decimal

class NutritionPrediction(NutritionReference):
    basis: Literal["creatorStated", "usdaCalculated", "unknown"]

def nutrition_case_passes(
    reference: NutritionReference,
    prediction: NutritionPrediction | None,
) -> bool: ...
```

Tests must prove:

- missing nutrition fails;
- an incorrect serving count fails;
- calories outside 10% fail;
- each macro outside `max(2 g, 10%)` fails;
- all fields must pass together;
- `unknown` basis fails even when numbers happen to match; and
- a suite passes only at `passed / total >= 0.95`.

Also define structural measurements for stated cook time, ingredient
name/quantity pairs, and ordered reference step phrases without treating them
as the nutrition gate.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/evaluation/test_extraction.py
```

Expected: import failure because `ladle.evaluation.extraction` does not exist.

**Step 3: Implement the scorer**

Implement decimal-safe relative error and suite summaries. Keep tuning and
held-out fixture paths explicit so the evaluator cannot silently score its
tuning set as proof.

Update `scripts/eval_extraction.py` to require a reference fixture for scored
runs and emit JSON containing corpus name, prompt/model versions, every case,
whole-recipe pass count, pass rate, and failed fields.

Start the checked-in fixtures with small schema-valid cases that exercise the
scorer. They are scaffolding, not evidence of the 95% claim; Task 8 expands and
locks the real corpus.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/evaluation/test_extraction.py
```

Expected: all scorer tests pass.

**Step 5: Document and commit**

Update the evaluation section in
`docs/plans/2026-08-24-text-only-accuracy-pipeline-design.md` if implementation
details differ. Run `git diff --check`, then commit:

```bash
git add Backend/ladle/evaluation Backend/tests/unit/evaluation \
  Backend/tests/fixtures/evaluation Backend/scripts/eval_extraction.py \
  docs/plans/2026-08-24-text-only-accuracy-pipeline-design.md
git commit -m "test: add extraction accuracy gates"
```

### Task 2: Enforce the zero-vision production boundary

**Files:**
- Modify: `Backend/tests/unit/acquisition/test_provider_chain.py`
- Modify: `Backend/tests/unit/extraction/test_prompt.py`
- Modify: `Backend/tests/unit/deploy/test_vps_simplified_profile.py`
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`
- Modify: `Backend/ladle/acquisition/provider_chain.py`
- Modify: `Backend/ladle/extraction/prompt.py`
- Modify: `Backend/ladle/worker/runtime.py`
- Modify: `Backend/ladle/config.py`
- Modify: `Backend/deploy/vps/docker-compose.yml`
- Modify: `Backend/deploy/vps/env.example`
- Modify: `Backend/.env.example`

**Step 1: Write the failing boundary tests**

Add tests that prove:

```python
context = chain.acquire(sparse_source, job_id=uuid4())
assert primary.calls == ["metadata", "transcript:auto"]
assert vision.calls == 0
assert context.visual_observations == platform_text_only
```

Runtime tests must prove live workers never construct or inject a frame vision
provider or thumbnail observer. Deployment tests require both
`LADLE_FRAME_ANALYSIS_ENABLED=false` and
`LADLE_THUMBNAIL_ANALYSIS_ENABLED=false`.

Prompt tests must prove the payload calls platform-published sticker/alt text
`platformText` and contains no instruction that frames or thumbnails are
evidence. Preserve those strings only when their provenance is a platform page
field; never accept provider-produced frame observations.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/acquisition/test_provider_chain.py \
  tests/unit/extraction/test_prompt.py \
  tests/unit/deploy/test_vps_simplified_profile.py \
  tests/integration/imports/test_retry_reparse.py
```

Expected: current sparse paths call visual providers, the prompt describes
frames, and VPS thumbnail analysis defaults to true.

**Step 3: Remove production vision paths**

- Remove `vision` fallback calls from `ProviderChain.acquire`.
- Do not wire `_vision_provider` or `thumbnail_observer` in
  `build_worker_runtime`.
- Keep thumbnail download/storage for recipe-card display only.
- Change both feature defaults to false and the VPS profile to false.
- Remove provider-supplied visual fallback and server-media visual merge.
- Serialize trusted platform page text under `platformText`.
- Remove visual inference rules from `SYSTEM_PROMPT` and bump
  `PROMPT_VERSION`.

Delete now-dead construction helpers when no production caller remains; keep
the standalone vision module only if another explicit non-import feature still
uses it.

**Step 4: Verify green**

Run the command from Step 2 and confirm all tests pass with zero visual calls.

**Step 5: Document and commit**

Add `Backend/docs/text-only-extraction.md` recording the exact allowed and
forbidden inputs. Run `git diff --check`, then commit:

```bash
git add Backend/ladle Backend/tests Backend/deploy/vps Backend/.env.example \
  Backend/docs/text-only-extraction.md
git commit -m "feat: enforce text-only recipe acquisition"
```

### Task 3: Refuse unsupported sparse sources before extraction

**Files:**
- Create: `Backend/tests/unit/extraction/test_evidence_gate.py`
- Create: `Backend/ladle/extraction/evidence_gate.py`
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`
- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/imports/transitions.py`
- Modify: `Backend/ladle/contracts/imports.py`

**Step 1: Write the failing gate tests**

Define:

```python
class InsufficientTextEvidence(Exception):
    pass

def require_recipe_evidence(context: AcquiredVideoContext) -> None: ...
```

Tests must reject title-only, promotional-caption-only, and ingredient-name-
only contexts. They must accept a creator-linked written recipe or transcript
that supplies at least one real ingredient and one ordered cooking action.

Integration tests must prove a rejected source never calls the extractor and
finishes with diagnostic `insufficientTextEvidence` rather than persisting an
inferred recipe.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/extraction/test_evidence_gate.py \
  tests/integration/imports/test_retry_reparse.py
```

Expected: missing module and current extractor call on sparse context.

**Step 3: Implement the gate**

Use evidence types and coverage—not title keywords—to decide whether a recipe
is supported. Call the gate after all text acquisition/search and before
structured extraction. Add the explicit diagnostic/failure mapping without
creating a placeholder recipe.

**Step 4: Verify green and commit**

Run the command from Step 2, then `git diff --check`. Update
`Backend/docs/text-only-extraction.md` and commit:

```bash
git add Backend/ladle Backend/tests Backend/docs/text-only-extraction.md
git commit -m "fix: refuse recipes without text evidence"
```

### Task 4: Add creator-validated sparse-source web search

**Files:**
- Create: `Backend/ladle/acquisition/search.py`
- Create: `Backend/tests/unit/acquisition/test_search.py`
- Modify: `Backend/ladle/acquisition/provider_chain.py`
- Modify: `Backend/ladle/worker/runtime.py`
- Modify: `Backend/ladle/config.py`
- Modify: `Backend/.env.example`
- Modify: `Backend/tests/unit/acquisition/test_provider_chain.py`
- Modify: `Backend/tests/unit/test_config.py`

**Step 1: Write failing search and chain tests**

Specify these interfaces:

```python
class SearchCandidate(WireModel):
    url: str
    title: str
    snippet: str

class RecipeSearchClient(Protocol):
    def search(self, queries: list[str], *, job_id: UUID) -> list[SearchCandidate]: ...

class SparseTextEnricher:
    def enrich(
        self, context: AcquiredVideoContext, *, job_id: UUID
    ) -> list[LinkedDocument]: ...
```

Tests must prove query generation uses creator/title/canonical identity,
several candidates can be inspected, fetched pages go through the existing
SSRF-safe text fetcher, and only pages tied to the creator or canonical post
are accepted. Reject generic same-dish pages, search snippets without fetched
content, thin pages, and pages without quantities/method.

Provider-chain tests must prove search runs only after ordinary text and
transcription remain insufficient and that search failure still makes zero
vision calls.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/acquisition/test_search.py \
  tests/unit/acquisition/test_provider_chain.py
```

Expected: missing search implementation.

**Step 3: Implement bounded textual search**

Implement an OpenRouter text-search client using the documented
`openrouter:web_search` server tool. Ask for candidate URLs/titles/snippets,
then independently fetch and validate pages; model assertions about authorship
are never sufficient. Configure maximum queries/results for worker stability,
not a dollar cap.

Wire the enricher after transcript fallbacks and before the evidence gate.
Append `creatorSearchUsed`, `creatorSearchUnavailable`, or
`creatorSearchNoMatch` diagnostics.

**Step 4: Verify green and commit**

Run the focused tests, Ruff and mypy on the new module, then update
`Backend/docs/text-only-extraction.md`, run `git diff --check`, and commit:

```bash
git add Backend/ladle Backend/tests Backend/.env.example \
  Backend/docs/text-only-extraction.md
git commit -m "feat: find creator recipes from sparse shares"
```

### Task 5: Preserve nutrition provenance and forbid model estimates

**Files:**
- Modify: `Backend/ladle/extraction/models.py`
- Modify: `Backend/ladle/extraction/prompt.py`
- Modify: `Backend/ladle/extraction/review.py`
- Modify: `Backend/ladle/recipes/template_clone.py`
- Modify: `Backend/tests/unit/extraction/test_prompt.py`
- Modify: `Backend/tests/unit/extraction/test_review.py`
- Modify: `Backend/tests/unit/extraction/test_claude.py`

**Step 1: Write failing provenance tests**

Add internal provenance types:

```python
NutritionBasis = Literal["creatorStated", "usdaCalculated", "unknown"]

class ExtractedNutrition(WireModel):
    ...
    basis: NutritionBasis
    evidence: str | None = None
```

Tests must prove creator-stated macros become `is_estimated=False`; absent
creator macros remain `nutrition=None`; a model response cannot label its own
estimate `usdaCalculated`; and the prompt explicitly forbids estimating
nutrition or inventing servings needed for division.

Retain internal metric amount/unit and a normalized USDA search phrase on
`TemplateIngredient` so calculation does not have to reparse display text.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/extraction
```

Expected: missing basis fields and current prompt permission to estimate.

**Step 3: Implement provenance**

Bump `PROMPT_VERSION`. Update review construction to accept only
`creatorStated` model nutrition and mark it non-estimated. Preserve metric and
search fields internally without changing the public iOS contract.

**Step 4: Verify green and commit**

Run extraction unit tests, `git diff --check`, update the companion doc, and
commit:

```bash
git add Backend/ladle/extraction Backend/ladle/recipes \
  Backend/tests/unit/extraction Backend/docs/text-only-extraction.md
git commit -m "fix: ground extracted nutrition in source text"
```

### Task 6: Calculate nutrition from USDA FoodData Central

**Files:**
- Create: `Backend/ladle/nutrition/__init__.py`
- Create: `Backend/ladle/nutrition/usda.py`
- Create: `Backend/ladle/nutrition/calculator.py`
- Create: `Backend/tests/fixtures/providers/usda/search.json`
- Create: `Backend/tests/fixtures/providers/usda/food.json`
- Create: `Backend/tests/unit/nutrition/test_usda.py`
- Create: `Backend/tests/unit/nutrition/test_calculator.py`
- Modify: `Backend/ladle/config.py`
- Modify: `Backend/.env.example`
- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/worker/runtime.py`
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`

**Step 1: Write failing USDA client tests**

Specify:

```python
class FoodNutrients(WireModel):
    fdc_id: int
    description: str
    calories_per_100g: Decimal
    protein_grams_per_100g: Decimal
    carbohydrate_grams_per_100g: Decimal
    fat_grams_per_100g: Decimal
    portions: list[FoodPortion]

class USDAClient:
    def candidates(self, query: str) -> list[FoodNutrients]: ...
```

Tests use checked-in responses and prove nutrient IDs, units, portion weights,
timeouts, malformed responses, and API errors are handled without guessing.
Prefer Foundation, SR Legacy, and FNDDS generic foods over unrelated branded
results.

**Step 2: Write failing calculator tests**

Define:

```python
class NutritionCalculator:
    def calculate(self, template: RecipeTemplate) -> TemplateNutrition | None: ...
```

Cover grams, USDA portion weights for cups/tablespoons/counts, recipe totals,
per-serving division, creator-stated precedence, calorie/macro consistency,
ambiguous matches, missing material quantities, unknown servings, and trivial
to-taste exclusions. Require complete calories/protein/carbohydrate/fat or no
calculated nutrition.

**Step 3: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/nutrition
```

Expected: missing nutrition package.

**Step 4: Implement the client and calculator**

Use FoodData Central search/detail endpoints with an API key from settings.
Cache exact normalized query responses in-process first; add durable cache only
after evaluator evidence shows repeated network work is material. Do not add a
database migration speculatively.

Wire calculation after extraction and before verification. USDA failure leaves
creator-stated nutrition intact; otherwise add an actionable nutrition
uncertainty and needs-review status.

**Step 5: Verify green and commit**

Run nutrition unit tests and the retry integration tests. Run Ruff and mypy,
update `Backend/docs/text-only-extraction.md`, run `git diff --check`, and
commit:

```bash
git add Backend/ladle Backend/tests Backend/.env.example \
  Backend/docs/text-only-extraction.md
git commit -m "feat: calculate recipe nutrition from USDA data"
```

### Task 7: Add targeted evidence verification

**Files:**
- Create: `Backend/ladle/extraction/verification.py`
- Create: `Backend/tests/unit/extraction/test_verification.py`
- Modify: `Backend/ladle/extraction/protocol.py`
- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/worker/runtime.py`
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`

**Step 1: Write failing deterministic-check tests**

Define `VerificationIssue` with field path, reason, and supporting evidence.
Detect serving-basis mismatches, total-time arithmetic contradictions,
ingredient references outside bounds, calories grossly inconsistent with
macros, missing method ingredients, and conflicting source amounts.

Define a `RecipeVerifier` protocol that receives only the template, issues,
and relevant text spans, and can return field-level patches. Tests must prove
unflagged fields cannot be rewritten and unsupported patches are rejected.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/extraction/test_verification.py
```

Expected: missing verification module.

**Step 3: Implement deterministic and model verification**

Run deterministic checks first. Call a separate structured model only when
issues exist. Apply valid field patches, rerun checks once, then keep remaining
issues as uncertainties and needs-review. Record the verifier as a distinct
provider operation.

**Step 4: Verify green and commit**

Run verification and retry integration tests, Ruff, mypy, and
`git diff --check`; update the companion doc and commit:

```bash
git add Backend/ladle Backend/tests Backend/docs/text-only-extraction.md
git commit -m "feat: verify disputed recipe fields"
```

### Task 8: Build and lock the real held-out corpus

**Files:**
- Modify: `Backend/tests/fixtures/evaluation/text-only-tuning.json`
- Modify: `Backend/tests/fixtures/evaluation/text-only-held-out.json`
- Create: `Backend/docs/extraction-evaluation.md`
- Create: `Backend/docs/verification/2026-08-24-text-only-accuracy.md`

**Step 1: Curate reference data**

Build a versioned corpus from sources with permitted retention and explicit
servings, calories, protein, carbohydrate, fat, ingredients, method, and time.
Record URL, retrieval date, license/attribution, and source split. Do not copy
copyrighted prose when structured facts or short evidence excerpts suffice.

Use at least 20 tuning cases and 80 never-tuned held-out cases spanning:

- ingredient lists with metric and US customary units;
- fractions, ranges, counts, cans, sauces, and sub-preparations;
- creator-stated and USDA-calculated nutrition;
- short and long transcripts;
- caption-rich and linked-page recipes; and
- at least 20 separate sparse/no-match/search cases for the 100% safety gate.

**Step 2: Validate fixtures without model calls**

Add schema and split-integrity checks to
`tests/unit/evaluation/test_extraction.py`: unique identities, no overlap,
complete nutrition references, supported licenses, and fixed corpus digest.

Run:

```bash
cd Backend
uv run pytest -q tests/unit/evaluation/test_extraction.py
```

Expected: all corpus integrity tests pass.

**Step 3: Benchmark models and prompts**

Run tuning cases while iterating. Freeze prompt/model configuration, then run
held-out cases exactly once for the milestone. Store sanitized predictions,
usage, and scorer output without secrets or full copyrighted pages.

Required results:

- at least 76 of 80 held-out nutrition cases pass as whole recipes;
- 100% of sparse cases either validate a creator page or refuse;
- zero visual-provider calls;
- structural metrics and every failure are recorded, not hidden by averages.

If the gate fails, diagnose the failure clusters, add tuning cases that model
the pattern without moving held-out cases, implement one tested correction,
and rerun a new versioned held-out evaluation.

**Step 4: Document and commit evidence**

Record exact commands, prompt/model versions, corpus digest, pass counts,
field errors, sparse results, and limitations. Run `git diff --check`, then
commit:

```bash
git add Backend/tests/fixtures/evaluation Backend/docs
git commit -m "test: verify text-only extraction accuracy"
```

### Task 9: Record actual provider cost without limiting accuracy

**Files:**
- Create: `Backend/alembic/versions/0013_add_provider_cost_usd.py`
- Modify: `Backend/ladle/db/models.py`
- Modify: `Backend/ladle/usage/ledger.py`
- Modify: `Backend/ladle/acquisition/audio.py`
- Modify: `Backend/ladle/extraction/claude.py`
- Modify: `Backend/ladle/extraction/openrouter.py`
- Modify: `Backend/tests/integration/usage/test_budget_reservations.py`
- Modify: `Backend/tests/integration/test_migrations.py`
- Modify: `Backend/tests/unit/extraction/test_openrouter.py`

**Step 1: Write failing accounting tests**

Add `cost_usd Numeric(18, 8)` independently from proprietary billed units.
Tests prove OpenRouter `usage.cost` is parsed, transcription and extraction
record their actual cost, retries accumulate rather than overwrite cost, and
no per-job threshold rejects a call.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q \
  tests/unit/extraction/test_openrouter.py \
  tests/integration/usage/test_budget_reservations.py \
  tests/integration/test_migrations.py
```

Expected: missing `cost_usd` schema and response field.

**Step 3: Implement and migrate**

Propagate provider-reported USD separately from existing quota units. Preserve
current daily call/credit controls unless they conflict with approved accuracy
evaluation; the removed requirement is the three-cent per-share ceiling, not
all abuse protection.

**Step 4: Verify green and commit**

Run focused tests, migration upgrade/downgrade coverage, Ruff, mypy, and
`git diff --check`; update provider-budget documentation and commit:

```bash
git add Backend/alembic Backend/ladle Backend/tests Backend/docs
git commit -m "feat: record provider cost in dollars"
```

### Task 10: Full milestone verification

**Files:**
- Modify: `Backend/docs/verification/2026-08-24-text-only-accuracy.md`

**Step 1: Run complete backend verification**

Run:

```bash
cd Backend
uv run pytest -q
uv run ruff check ladle tests scripts
uv run mypy ladle
```

Expected: all tests pass, with only explicitly documented live-provider skips.

**Step 2: Run shared and app contract verification**

Because public recipe nutrition behavior crosses the backend/iOS contract,
run:

```bash
swift test --package-path Packages/LadleCore
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath /tmp/ladle-text-accuracy-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LadleTests/RemoteImportServiceTests \
  -only-testing:LadleTests/RecipeEditorViewModelTests
```

Expected: all selected tests pass and the Share Extension is embedded and
validated during build.

**Step 3: Run the accuracy audit**

Run the frozen held-out evaluator and inspect every failed case. Confirm the
nutrition pass count is at least 95%, sparse correctness is 100%, visual calls
are zero, and cost is reported but not used as an acceptance limit.

**Step 4: Finish documentation and commit**

Record fresh outputs, corpus digest, revisions, and unresolved limitations.
Run:

```bash
git diff --check
git status --short
```

Commit only the verification record:

```bash
git add Backend/docs/verification/2026-08-24-text-only-accuracy.md
git commit -m "docs: verify text-only extraction accuracy"
```
