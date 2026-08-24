# Text-only accuracy verification — 2026-08-24

## Status

The pipeline implementation and locked reference corpus are ready, but the
95% held-out milestone is **not yet proven**. This workspace has no OpenRouter,
Anthropic, or USDA API key, so no model prediction was substituted or inferred
for the missing run.

## Frozen inputs awaiting provider execution

- Prompt: `recipe-2026-08-24-v10`
- Default model: `google/gemini-3.6-flash`
- Tuning fixture: `public-domain-v1`, 20 nutrition cases
- Tuning digest: `3461ea84be082f52436c70e38537bda708ca1719de0e362f792da876a8063eee`
- Held-out fixture: `public-domain-v1`, 80 nutrition cases and 20 safety cases
- Held-out digest: `7153942ffc57e90a979c8e988e9d784133580091ae36c04068677687404ccd9b`
- Nutrition threshold: 95% whole-recipe cases (at least 76/80)
- Sparse threshold: 100% (20/20)
- Visual-provider threshold: zero calls

The held-out fixture has not been used for prompt or model tuning.

Implementation checkpoints:

- `3e271ab` — zero visual-analysis acquisition/runtime paths
- `eef794a` — insufficient-text refusal
- `a4d66b8` — creator-owned written-recipe search
- `4789012` — creator nutrition provenance
- `90414ed` — deterministic USDA nutrition
- `34cab87` — targeted text-evidence verification
- `3a0210d` — locked 20/80 corpus and whole-recipe evaluator
- `8129b97` — provider-reported USD accounting without a per-share limit

## Completed evidence

```text
.venv/bin/pytest tests/unit/evaluation/test_extraction.py -q
18 passed

.venv/bin/pytest tests/unit/evaluation/test_extraction.py \
  tests/unit/nutrition/test_calculator.py -q
31 passed

.venv/bin/ruff check scripts/eval_extraction.py \
  scripts/build_evaluation_corpus.py ladle/evaluation/extraction.py \
  tests/unit/evaluation/test_extraction.py \
  tests/unit/nutrition/test_calculator.py
All checks passed

.venv/bin/mypy scripts/eval_extraction.py \
  scripts/build_evaluation_corpus.py ladle/evaluation/extraction.py
Success: no issues found in 3 source files

.venv/bin/pytest tests/unit tests/contracts -q
516 passed

.venv/bin/ruff check ladle scripts tests
All checks passed

.venv/bin/mypy ladle
Success: no issues found in 117 source files

.venv/bin/mypy scripts/eval_extraction.py \
  scripts/build_evaluation_corpus.py
Success: no issues found in 2 source files

.venv/bin/pytest tests/unit/extraction/test_openrouter.py \
  tests/unit/extraction/test_claude.py \
  tests/unit/extraction/test_verification.py \
  tests/unit/acquisition/test_audio.py -q
54 passed

.venv/bin/pytest tests/integration/usage/test_budget_reservations.py \
  tests/integration/test_migrations.py -q
9 passed

.venv/bin/pytest -q
605 passed, 5 skipped

.venv/bin/ruff check ladle tests scripts alembic
All checks passed

swift test --package-path Packages/LadleCore
44 tests passed

xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  -derivedDataPath /tmp/ladle-text-accuracy-derived \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LadleTests/RemoteImportServiceTests \
  -only-testing:LadleTests/RecipeEditorViewModelTests
10 tests passed; TEST SUCCEEDED

Ladle.app/PlugIns/LadleShare.appex present
NSExtensionPointIdentifier = com.apple.share-services
```

The fixture integrity tests independently recompute both digests, confirm no
tuning/held-out identity overlap, and exercise all 20 sparse cases through the
production `require_recipe_evidence` gate. Those deterministic sparse cases
pass 20/20. Production construction and evaluation contexts both contain an
empty visual-evidence list, and the model clients accept text only.

Provider accounting tests additionally prove that OpenRouter-reported cost is
parsed for extraction and targeted verification, transcription reports cost,
the database stores `Numeric(18, 8)`, a two-attempt structured-output retry
adds both token and cost totals, and repeated processing accumulates cost
without double-counting idempotent completion. A reported `$999.25` second-run
cost did not reject the call; only its independent billed-unit reservation
affected the global abuse-control window.

The five full-suite skips are explicitly live-provider integration cases. The
testcontainers Redis deprecation warning is upstream test-library noise. The
iOS simulator emitted a duplicate accessibility-bundle runtime warning, but
all selected tests passed and the built app contains a validated Share
Extension.

## Blocked provider run

Command attempted:

```text
.venv/bin/python scripts/eval_extraction.py extract \
  --corpus tuning --label credentials-check --only tuning-usda-002
```

Observed result:

```text
RuntimeError: evaluation requires LADLE_USDA_API_KEY for calculated-nutrition cases
```

Environment presence checks also found no `LADLE_OPENROUTER_API_KEY`,
`OPENROUTER_API_KEY`, `LADLE_ANTHROPIC_API_KEY`, `ANTHROPIC_API_KEY`,
`LADLE_USDA_API_KEY`, or `USDA_API_KEY`. No secret value was printed.

An additional broad `mypy ladle scripts` invocation reached two unrelated,
pre-existing script findings in `restore_drill.py` (an untyped third-party
package) and `e2e_import.py` (a bare `dict`). The full application package and
both changed evaluation scripts pass strict mypy independently as recorded
above.

## Required continuation

1. Provide `LADLE_USDA_API_KEY` and either the configured OpenRouter or
   Anthropic key.
2. Run and inspect the 20-case tuning partition.
3. Freeze any resulting prompt/model revision under new versions.
4. Run the 80-case held-out partition exactly once for that revision.
5. Record the generated result filename, pass count, failed fields, token
   usage, sparse count, and zero-vision count here.
6. Do not claim the 95% milestone unless the stored result reports at least
   76/80, 20/20 sparse safety, and zero visual-provider calls.

## Known limitations

- The stable corpus measures the text extraction and nutrition stages, not
  live social-platform acquisition or search recall.
- Four held-out cases require USDA calculation. The other 76 retain a
  publisher-stated nutrition panel and test exact extraction plus serving-basis
  normalization.
- USDA calculation refuses ambiguous food matches or unsupported quantities;
  these refusals correctly fail a nutrition benchmark case rather than
  becoming model estimates.
