# Pipeline Validator HTML Verification

## Outcome

The validation bundle consists of a standalone five-recipe report, a live link
validator, and a loopback-only Python helper. The helper pins extraction and
verification to `google/gemini-3.7-flash`; it does not place API credentials in
HTML, HTTP job state, browser storage, or committed files.

## Artifacts

- `tools/pipeline-results.html` embeds sanitized copies of the five successful
  TikTok and Instagram recipes from the 2026-08-24 live run.
- `tools/pipeline-validator.html` accepts one supported link and renders the
  returned serving count and basis, recipe, timers, review state, uncertainties,
  latency, and reported cost.
- `scripts/serve_pipeline_validator.py` serves both pages on `127.0.0.1`, admits
  one active run, and keeps ephemeral job state in memory.

## Launch

From `Backend`:

```bash
.venv/bin/python scripts/serve_pipeline_validator.py
```

The script reads `LADLE_OPENROUTER_API_KEY` and `LADLE_USDA_API_KEY` from the
environment. If either is absent it prompts in the terminal without echoing.
To validate the interface without provider calls or credentials:

```bash
.venv/bin/python scripts/serve_pipeline_validator.py --demo
```

## Evidence

Verification performed on 2026-08-24:

- Focused helper and artifact suite: 11 passed.
- Full backend suite: 657 passed, 5 skipped, with one upstream testcontainers
  deprecation warning.
- Full Ruff check: clean.
- Strict mypy for the repository's `ladle` target: no issues in 119 source
  files. The new standalone helper also passed a focused strict mypy check.
- Both inline JavaScript programs passed `node --check` after extraction from
  their HTML files.
- The demo server returned `200 text/html` for the validator and results pages.
- A demo Instagram URL was admitted through `POST /api/validate`, polled through
  `GET /api/jobs/{id}`, and reached `succeeded` with a two-serving, stated-basis
  recipe and zero reported demo cost.
- Artifact assertions cover the five canonical source URLs, five recipe
  records, servings and basis, ingredients, steps, review flags, processing
  time, the $0.0783865776875 aggregate known-cost lower bound, semantic
  landmarks, viewport and reduced-motion behavior, absence of external scripts,
  and absence of the OpenRouter key prefix.
- Validator assertions cover its labeled URL form, polite live region,
  servings/basis and full recipe outputs, setup guidance for direct-file use,
  abort-safe polling, safe text-node rendering, and both static routes.
- `git diff --check` is part of the final checkpoint.

## Browser limitation

The in-app browser refused `http://127.0.0.1:8765` under its URL security
policy. No workaround or alternate browser automation was used. Consequently,
this session did not produce desktop/mobile screenshots. Responsive CSS and DOM
contracts were checked statically, while the HTTP and asynchronous job behavior
were exercised against the running demo helper. A normal local browser can
perform the remaining visual inspection with the demo launch command above.

## Spend

UI verification used `--demo`; it made no paid OpenRouter, USDA, search, or
transcription call. The report data came from the already completed five-link
run and does not initiate new work when opened.
