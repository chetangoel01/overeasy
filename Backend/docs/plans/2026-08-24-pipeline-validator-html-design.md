# Pipeline Validator HTML Design

## Purpose

Give the user a visual record of the five Gemini 3.7 live recipes and a small,
safe tool for validating additional TikTok or Instagram links against the same
current-branch pipeline.

## Deliverables

- `tools/pipeline-results.html`: a standalone report with the five recipes,
  servings, review warnings, ingredients, steps, latency, and known cost
  embedded directly in the file.
- `tools/pipeline-validator.html`: a link-entry interface that shows acquisition
  and extraction progress, then emphasizes the resulting serving count and
  basis alongside the full recipe and uncertainties.
- `scripts/serve_pipeline_validator.py`: a localhost-only server that serves
  both pages and proxies validator jobs into Ladle's real acquisition,
  evidence-gate, Gemini 3.7 extraction, USDA, review, and verification
  components.

## Visual direction

Use an editorial test-kitchen notebook rather than a generic dashboard: warm
paper, dark ink, vermilion status accents, fine rules, oversized serif recipe
titles, compact lab labels, and staggered page-load reveals. Keep the dense
recipe data readable on desktop and mobile, respect reduced-motion settings,
and retain keyboard-visible focus states and semantic headings.

## Data flow and safety

The helper binds only to `127.0.0.1`, accepts one active validation job at a
time, and keeps job state in memory. The HTML submits only the source URL and
polls an opaque job ID. Provider keys come from environment variables or an
interactive terminal prompt and never enter HTML, browser storage, job JSON,
logs, or committed files. Directly opening the validator as `file://` shows a
clear command to start the helper because browser CORS prevents a standalone
file from reading the API.

Terminal errors remain results: invalid URLs, sparse evidence, provider
failures, and schema failures appear with their typed message and do not fall
back to another model. The helper pins extraction and verification to
`google/gemini-3.7-flash` and exposes no public listener.

## Verification

- Test URL validation, job admission, single-job spend protection, success and
  failure serialization, and secret absence with injected fake pipelines.
- Validate both HTML documents and their embedded data/DOM hooks.
- Run the focused server tests, Ruff, mypy, and `git diff --check`.
- Start the helper with a fake pipeline, exercise both pages in a browser at
  desktop and mobile widths, and inspect screenshots for overflow, hierarchy,
  loading, success, and error states.

## Implementation record

The localhost job service is covered by eight focused unit tests. The tests
exercise canonical URLs, invalid input, job admission and polling, one-active-
job enforcement, typed failures, and configured-secret redaction. On
2026-08-24 those tests passed together with focused Ruff and mypy checks.

The standalone report embeds sanitized copies of all five successful recipe
records: their ingredients, steps, servings and basis, review state,
uncertainties, processing time, and known cost. An artifact test verifies all
five canonical sources, the $0.0783866 aggregate known cost, responsive and
reduced-motion hooks, and the absence of external scripts or key prefixes.

The interactive page submits a single source URL to the same-origin helper,
polls a typed in-memory job, and renders every returned string through DOM text
nodes. It highlights servings and their stated/estimated basis, then exposes
ingredients, steps, timers, review status, field uncertainties, elapsed time,
and reported cost. Direct `file://` use is disabled with a local launch command
because the live API is intentionally available only through loopback.
