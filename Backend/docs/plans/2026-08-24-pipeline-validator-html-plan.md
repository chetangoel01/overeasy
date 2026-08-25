# Pipeline Validator HTML Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a standalone five-recipe HTML report and a localhost-served HTML validator that runs new links through the current Gemini 3.7 pipeline and emphasizes servings.

**Architecture:** A small FastAPI helper binds only to loopback, serves the two static HTML files, admits one in-memory validation job at a time, and runs the existing acquisition/extraction components in a worker thread. The browser posts only a source URL and polls job state; provider secrets remain in the terminal process.

**Tech Stack:** Python 3.12, FastAPI, uvicorn, existing Ladle pipeline components, pytest, vanilla semantic HTML/CSS/JavaScript.

---

### Task 1: Build the testable validation job boundary

**Files:**
- Create: `Backend/tests/unit/scripts/test_serve_pipeline_validator.py`
- Create: `Backend/scripts/serve_pipeline_validator.py`

**Step 1: Write failing tests**

Cover:

- valid TikTok/Instagram URL admission and canonicalization;
- invalid/unsupported URL rejection before a job is created;
- one-active-job enforcement;
- progress, success, and typed failure state serialization;
- `/api/validate`, `/api/jobs/{id}`, `/`, and the results-page route;
- returned state and HTML responses contain no configured secret fragments.

Use an injected fake runner and executor; no network or paid provider calls.

**Step 2: Verify red**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/scripts/test_serve_pipeline_validator.py -q
```

Expected: collection fails because `scripts.serve_pipeline_validator` does not
exist.

**Step 3: Implement the minimal server**

Create:

- `ValidationRunner` protocol;
- `ValidationJobService` with locked in-memory job state and one active job;
- `create_app(service)` returning the static and JSON routes;
- `LiveValidationRunner` using `SourceIdentityParser`, `ProviderChain`,
  `require_recipe_evidence`, and the existing evaluation pipeline pinned to
  `google/gemini-3.7-flash`;
- terminal secret prompting when environment variables are absent;
- a loopback-only uvicorn CLI with an optional browser launch.

All recipe/model strings sent to the browser remain plain JSON; HTML rendering
must use `textContent`, not model-controlled `innerHTML`.

**Step 4: Verify green**

Run the focused tests, Ruff, and mypy for the server and tests.

**Step 5: Commit**

Commit the tested server boundary independently from the presentation files.

### Task 2: Build the standalone results report

**Files:**
- Create: `Backend/tools/pipeline-results.html`
- Modify: `Backend/tests/unit/scripts/test_serve_pipeline_validator.py`

**Step 1: Add a failing artifact test**

Assert the HTML has semantic landmarks, the five canonical URLs, five embedded
recipe records, servings and basis fields, review warnings, cost/latency data,
responsive viewport metadata, and no secret fragments or external scripts.

**Step 2: Verify red**

Run the focused artifact test and confirm the missing file fails it.

**Step 3: Implement the report**

Create the warm editorial test-kitchen page with embedded sanitized recipe data,
summary metrics, recipe navigation, ingredient and step layouts, review flags,
and mobile/reduced-motion behavior. Keep it fully self-contained.

**Step 4: Verify green and commit**

Run the artifact test and `git diff --check`, then commit the report.

### Task 3: Build the live validator page

**Files:**
- Create: `Backend/tools/pipeline-validator.html`
- Modify: `Backend/tests/unit/scripts/test_serve_pipeline_validator.py`

**Step 1: Add failing page-contract tests**

Assert the page includes an accessible URL form, stage/status live region,
servings/basis output, ingredients, steps, review uncertainties, abort-safe
polling, file-protocol setup guidance, and no model-controlled `innerHTML`.

**Step 2: Verify red**

Run the new page tests and confirm failure because the file is absent.

**Step 3: Implement the validator**

Use relative same-origin API calls, disable the form while a job is active,
poll with bounded delay, show typed failures, and render all provider/model text
through DOM `textContent`. Make servings the visual focal point while showing
the basis and uncertainty prominently enough to catch bad estimates.

**Step 4: Verify green and commit**

Run focused tests, Ruff, mypy, and `git diff --check`; commit the page and its
tests.

### Task 4: Browser and repository verification

**Files:**
- Modify: `Backend/docs/plans/2026-08-24-pipeline-validator-html-design.md`
- Create: `Backend/docs/verification/2026-08-24-pipeline-validator-html.md`

**Step 1: Start a fake local helper**

Run the server with an injected deterministic fake pipeline so browser checks do
not spend provider money.

**Step 2: Inspect both pages**

At desktop and mobile widths, verify the report, validator idle state, loading
state, successful servings result, and typed error state. Capture screenshots
and check for overflow, clipped text, missing focus indicators, and console
errors.

**Step 3: Run final checks**

Run focused tests, full backend pytest, Ruff, mypy, and `git diff --check`.

**Step 4: Document and commit verification**

Record paths, launch command, behavior, browser findings, test evidence, and the
fact that no paid live calls were made for UI verification.

