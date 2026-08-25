# Text-only accuracy verification — 2026-08-24

## Status

Prompt v11 meets the numeric milestone on the complete public-domain
regression corpus: **76/80 whole-recipe nutrition cases (95.0%)**, **20/20
sparse refusals**, and **zero visual-provider calls**. All 76 cases retaining
an explicit publisher nutrition panel pass. The four failures are the four
cases whose panels were removed to require USDA calculation.

This is accurately described as a held-out-corpus regression result, not an
untouched one-shot estimate. Prompt v10 was run against the corpus first and
scored 75/80; its `held-nhlbi-060` max-token failure motivated the generic v11
change that makes model nutrition always null and leaves nutrition ownership
to deterministic server stages. Both runs and the failure remain recorded.

## Audited inputs

- Prompt: `recipe-2026-08-24-v11`
- Default model: `google/gemini-3.6-flash`
- Tuning fixture: `public-domain-v1`, 20 nutrition cases
- Tuning digest: `3461ea84be082f52436c70e38537bda708ca1719de0e362f792da876a8063eee`
- Held-out fixture: `public-domain-v1`, 80 nutrition cases and 20 safety cases
- Held-out digest: `4cc80ef9735e786feba6c42654b833bd2435775d85f64d060030ad61d0c5bf00`
- Nutrition threshold: 95% whole-recipe cases (at least 76/80)
- Sparse threshold: 100% (20/20)
- Visual-provider threshold: zero calls

Before the first provider run, the visibly incorrect `held-nhlbi-060` calorie
reference was repaired from 4 to 180: the retained publisher panel states 45
calories per serving and four servings, and the fixture builder independently
reproduces 180. The corrected digest above was used for both complete runs.

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

Final v11 suite:
.venv/bin/pytest -q
619 passed, 5 skipped

.venv/bin/ruff check ladle tests scripts alembic
All checks passed

.venv/bin/mypy ladle scripts/eval_extraction.py \
  scripts/build_evaluation_corpus.py
Success: no issues found in 120 source files

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

## Provider-backed results

Credentials were passed only through the evaluator process environment and
were not written to the repository or an `.env` file.

The initial v10 tuning run produced:

```text
result: .eval-cache/results/2026-08-24-openrouter-tuning.json
whole-recipe nutrition: 14/20 (70.0%)
extraction tokens: 106,023 input / 95,396 output
provider-reported extraction cost: $0.43725225
visual-provider calls: 0
```

The deterministic creator-facts layer corrected explicit yield, per-serving
basis, primary macros, and labeled times from exact text. Prompt v11 then made
model nutrition always null so a model cannot duplicate or expand a panel the
deterministic stage already owns. The complete v11 tuning run produced:

```text
result: .eval-cache/results/2026-08-24-v11-tuning.json
whole-recipe nutrition: 15/20 (75.0%)
creator-panel cases: 15/15
extraction tokens: 100,535 input / 84,448 output
provider-reported extraction cost: $0.39208125
visual-provider calls: 0
```

One tuning USDA request returned HTTP 404; it remained a failed case. The
other four USDA-only tuning cases also returned no nutrition rather than
guessing.

The complete v10 held-out diagnostic produced 75/80 (93.75%), 20/20 sparse,
and zero visual calls. `held-nhlbi-060` failed because the model repeated its
nutrition evidence until `max_tokens`; the four USDA-only cases returned no
nutrition. The exact overflow case passed a v11 smoke run before the complete
v11 regression:

```text
result: .eval-cache/results/2026-08-24-v11-held-out-regression.json
corpus digest: 4cc80ef9735e786feba6c42654b833bd2435775d85f64d060030ad61d0c5bf00
whole-recipe nutrition: 76/80 (95.0%), gate PASS
sparse safety: 20/20, gate PASS
visual-provider calls: 0, gate PASS
extraction tokens: 392,131 input / 269,254 output
provider-reported extraction cost: $1.30380075
```

An independent digest recomputation matched the result. The only failed rows
were `held-usda-001` through `held-usda-004`, all with expected basis
`usdaCalculated`, no prediction, and failed field `nutrition`.

## Known limitations

- The stable corpus measures the text extraction and nutrition stages, not
  live social-platform acquisition or search recall.
- Four held-out cases require USDA calculation. The other 76 retain a
  publisher-stated nutrition panel and test exact extraction plus serving-basis
  normalization.
- Prompt v11 was informed by the initial v10 held-out diagnostic, so the 95%
  result is regression evidence on this corpus rather than a statistically
  untouched estimate of general social-recipe accuracy.
- USDA calculation refuses ambiguous food matches or unsupported quantities;
  these refusals correctly fail a nutrition benchmark case rather than
  becoming model estimates.
