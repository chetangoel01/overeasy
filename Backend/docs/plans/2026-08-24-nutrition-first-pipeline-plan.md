# Nutrition-First Recipe Pipeline Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce auditable calories and primary macros for real recipe imports by using Gemini 3.7 to normalize missing yield and ingredient weights, USDA to calculate nutrition, and visible confidence/assumptions in both validation HTML files.

**Architecture:** Add a specialized, structured nutrition normalizer that converts every energy-bearing ingredient to grams and estimates missing yield without calculating calories. A nutrition enrichment service protects creator-stated facts, applies the normalization, invokes a diagnostic USDA calculator, and returns either a complete estimated panel or a typed review blocker. Wire the same service into production imports and the evaluation/validator pipeline.

**Tech Stack:** Python 3.12, Pydantic, httpx, OpenRouter JSON Schema, USDA FoodData Central, FastAPI, pytest, vanilla HTML/CSS/JavaScript.

---

### Task 1: Define and apply structured nutrition normalization

**Files:**
- Create: `Backend/ladle/nutrition/normalization.py`
- Create: `Backend/tests/unit/nutrition/test_normalization.py`

**Step 1: Write failing domain tests**

Cover these behaviors with an injected client:

```python
def test_stated_servings_and_raw_quantities_are_protected() -> None:
    result = service(response(servings="8")).normalize(
        template(servings="2", servings_basis="stated"),
        context(),
        job_id=uuid4(),
    )
    assert result.template.servings == 2
    assert result.template.servings_basis == "stated"
    assert result.template.ingredients[0].quantity_text == "1 cup"


def test_estimated_yield_and_ingredient_grams_are_applied() -> None:
    result = service(response(servings="4", grams="396.9")).normalize(
        template(servings="1", servings_basis="estimatedFromYield"),
        context(),
        job_id=uuid4(),
    )
    assert result.template.servings == 4
    assert result.template.ingredients[0].metric_amount == Decimal("396.9")
    assert result.template.ingredients[0].metric_unit == "g"
    assert result.servings_confidence == Decimal("0.95")
```

Also test duplicate/out-of-range ingredient indexes, missing material ingredients,
bounded assumptions, and explicit exclusion of water/to-taste ingredients.

**Step 2: Verify red**

Run:

```bash
.venv/bin/pytest tests/unit/nutrition/test_normalization.py -q
```

Expected: collection fails because `ladle.nutrition.normalization` is absent.

**Step 3: Implement the minimal domain boundary**

Add Pydantic models equivalent to:

```python
class NormalizedIngredient(WireModel):
    ingredient_index: int = Field(ge=0)
    usda_search_term: str = Field(min_length=1)
    grams: Decimal = Field(gt=0)
    was_inferred: bool
    rationale: str = Field(min_length=1, max_length=500)


class NutritionNormalization(WireModel):
    servings: Decimal = Field(gt=0)
    servings_confidence: Decimal = Field(ge=0, le=1)
    servings_rationale: str = Field(min_length=1, max_length=1_000)
    ingredients: list[NormalizedIngredient]
    excluded_ingredient_indexes: list[int] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list, max_length=20)


@dataclass(frozen=True)
class NormalizedRecipe:
    template: RecipeTemplate
    servings_confidence: Decimal
    servings_rationale: str
    assumptions: tuple[str, ...]
```

Define `NutritionNormalizationClient` and `RecipeNutritionNormalizer`. Require
exactly one normalized-or-excluded record for every non-to-taste ingredient,
protect stated servings and raw quantity text, apply grams and simple USDA terms,
and attach a servings uncertainty when the yield remains estimated.

**Step 4: Verify green and commit**

Run the new tests, Ruff, mypy, and `git diff --check`; commit the domain change.

### Task 2: Add the Gemini 3.7/OpenRouter normalization client

**Files:**
- Modify: `Backend/ladle/nutrition/normalization.py`
- Create: `Backend/tests/unit/nutrition/test_normalization_openrouter.py`
- Modify: `Backend/ladle/config.py`
- Modify: `Backend/tests/unit/test_config.py`

**Step 1: Write failing transport tests**

Use `httpx.MockTransport` to assert:

- model is pinned to `google/gemini-3.7-flash` by default;
- the prompt includes real evidence and the current reviewed recipe;
- the JSON schema requests grams, serving confidence, rationales, exclusions,
  and assumptions, but contains no calorie/macro output field;
- one 429 receives exactly one retry and a second 429 raises
  `NutritionNormalizationUnavailable`;
- malformed structured output is typed and provider errors contain no key.

**Step 2: Verify red, implement, and verify green**

Add settings:

```python
nutrition_normalization_enabled: bool = True
nutrition_normalization_model_id: str = "google/gemini-3.7-flash"
nutrition_normalization_max_tokens: int = Field(default=5000, gt=0)
```

Implement `OpenRouterNutritionNormalizationClient` with temperature zero,
`provider.require_parameters=true`, strict JSON Schema, a single bounded retry
only for HTTP 429, and provider usage recording under
`nutritionNormalization`. Run focused tests, Ruff, mypy, and commit.

### Task 3: Make USDA calculation diagnostic and estimated-yield capable

**Files:**
- Modify: `Backend/ladle/nutrition/calculator.py`
- Modify: `Backend/tests/unit/nutrition/test_calculator.py`

**Step 1: Write failing calculator tests**

Replace the old “estimated servings return None” expectation with:

```python
def test_calculates_with_a_normalized_estimated_yield() -> None:
    value = ingredient(metric_amount="400", metric_unit="g")
    result = NutritionCalculator(source).calculate_required(
        recipe([value], servings="4", servings_basis="estimatedFromYield")
    )
    assert result.calories == Decimal("70.0")
    assert result.is_estimated
```

Add cases asserting typed blockers for missing food matches, ambiguous matches,
inconsistent USDA macros, missing grams, and invalid yields. Each blocker must
include the ingredient index/name where applicable.

**Step 2: Verify red**

Run the focused calculator tests and confirm `calculate_required` is missing.

**Step 3: Implement the diagnostic path**

Add `NutritionCalculationUnavailable(code, ingredient_index, ingredient_name)`
and `calculate_required(template)`. Permit `stated` and `estimatedFromYield`
divisors, retain creator panels, calculate only from grams after normalization,
and raise instead of silently returning `None`. Keep `calculate()` as a
backward-compatible wrapper returning `None` on the typed exception.

**Step 4: Verify green and commit**

Run all nutrition unit tests, Ruff, mypy, and `git diff --check`; commit.

### Task 4: Compose normalization and USDA into one enrichment service

**Files:**
- Create: `Backend/ladle/nutrition/service.py`
- Create: `Backend/tests/unit/nutrition/test_service.py`

**Step 1: Write failing service tests**

Test creator-panel precedence, successful normalization plus USDA calculation,
evidence containing FDC IDs/confidence/assumptions, typed normalization failure,
typed USDA blocker, and `needsReview` rather than a silent ready recipe.

The primary API should be:

```python
class RecipeNutritionService:
    def enrich(
        self,
        template: RecipeTemplate,
        *,
        context: AcquiredVideoContext,
        job_id: UUID,
    ) -> RecipeTemplate: ...
```

Failures return the recipe with `review_status=needsReview` and one `nutrition`
uncertainty containing a specific blocker. Success returns a nutrition panel and
removes any stale nutrition uncertainty.

**Step 2: Verify red, implement, and verify green**

Keep all calorie/macro arithmetic in `NutritionCalculator`. Add normalization
confidence and assumptions to the existing nutrition evidence string so the
current API contract persists the audit trail without a schema migration. Run
focused tests and commit.

### Task 5: Wire the service into production and evaluation pipelines

**Files:**
- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/worker/runtime.py`
- Modify: `Backend/scripts/eval_extraction.py`
- Modify: `Backend/scripts/serve_pipeline_validator.py`
- Modify: `Backend/tests/integration/imports/test_retry_reparse.py`
- Modify: `Backend/tests/unit/worker/test_app.py`
- Modify: `Backend/tests/unit/scripts/test_eval_extraction.py`
- Modify: `Backend/tests/unit/scripts/test_serve_pipeline_validator.py`

**Step 1: Write failing wiring tests**

Assert creator facts run before nutrition enrichment, the enriched template runs
through verification before persistence, live runtime builds the service only
with USDA and OpenRouter credentials, evaluation uses the same service, validator
progress includes `normalizing` then `nutrition`, and usage includes the extra
model call.

**Step 2: Verify red, implement, and verify green**

Replace the orchestrator's calculator-only dependency with a `NutritionEnricher`
protocol. Build `RecipeNutritionService` in runtime and evaluation factories.
Do not normalize fake-provider imports. Run focused import/worker/script tests,
Ruff, mypy, `git diff --check`, and commit.

### Task 6: Render nutrition in both HTML artifacts

**Files:**
- Modify: `Backend/tools/pipeline-results.html`
- Modify: `Backend/tools/pipeline-validator.html`
- Modify: `Backend/tests/unit/scripts/test_serve_pipeline_validator.py`

**Step 1: Write failing page-contract tests**

Require calories, protein, carbohydrates, fat, per-serving/whole-recipe labels,
estimated status, serving confidence/assumptions, and typed nutrition blockers.
Continue to prohibit external scripts, model-controlled `innerHTML`, and key
fragments.

**Step 2: Verify red, implement, and verify green**

Add a nutrition panel that makes calories the focal number, renders primary
macros, derives whole-recipe values from per-serving values and yield, and shows
the evidence/assumptions beside estimated servings. Keep all provider text on
the validator on `textContent` paths. Run the artifact/server suite and commit.

### Task 7: Reprocess the five preserved real-link recipes

**Files:**
- Modify: `Backend/docs/verification/2026-08-24-pipeline-validator-html.md`
- Create: `Backend/docs/verification/2026-08-24-nutrition-first-live-recipes.md`
- Modify: `Backend/tools/pipeline-results.html`

**Step 1: Run without reacquisition or re-extraction**

Use the saved creator evidence and recipe templates. Run exactly one approved
normalization pass plus USDA enrichment per recipe; retain a single 429 retry.
Do not call transcription, search, or the main extraction model.

**Step 2: Inspect every result**

Report original versus normalized yield, per-serving and whole-recipe calories
and primary macros, confidence, assumptions, missing/ambiguous USDA blockers,
latency, and provider spend. Do not create synthetic reference labels.

**Step 3: Update the standalone results artifact**

Embed the enriched five recipe records and verified run totals. Ensure the
report visibly distinguishes creator-stated, USDA-calculated, and model-assisted
estimated facts.

**Step 4: Run final verification and commit**

Run:

```bash
.venv/bin/pytest tests/unit/nutrition tests/unit/scripts/test_serve_pipeline_validator.py -q
.venv/bin/pytest -q
.venv/bin/ruff check .
.venv/bin/mypy ladle
.venv/bin/mypy scripts/serve_pipeline_validator.py scripts/eval_extraction.py
git diff --check
```

Record exact results and the live-call cost, commit the verification artifacts,
and leave the feature branch clean.
