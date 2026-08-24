# OpenRouter Recipe Extraction Bake-Off Design

**Date:** 2026-08-24  
**Status:** Approved  
**Branch:** `codex/extraction-accuracy`

## Purpose

Identify the lowest-cost OpenRouter model that matches the best recipe extraction
quality on Ladle's frozen text-only evaluation corpus. Quality is the primary
selection criterion. Cost and latency can decide only between models with
comparable quality.

## Candidates

Run these pinned model IDs through the same end-to-end extraction and targeted
verification pipeline:

1. `deepseek/deepseek-v4-pro-0813`
2. `moonshotai/kimi-k3`
3. `google/gemini-3.7-flash`
4. `x-ai/grok-4.6`
5. `qwen/qwen3-235b-a22b-2507`
6. `anthropic/claude-opus-5` as the quality reference

The existing `google/gemini-3.6-flash` v11 result remains a historical baseline,
but it does not replace a fresh run of any candidate. Mutable `latest` aliases are
not used because a provider could redirect one during the benchmark.

## Experiment Protocol

Every candidate receives:

- the locked 80-case held-out corpus and its 20 sparse-safety cases;
- prompt `recipe-2026-08-24-v11` without candidate-specific changes;
- temperature zero, strict JSON-schema output, and required parameter support;
- the same text-only acquisition evidence, deterministic creator-facts parser,
  USDA calculator, and targeted verifier;
- the same model for initial extraction and that case's targeted verification;
- no visual provider calls.

Run all six candidates once. Rank them using the frozen rules below, then repeat
the two highest-quality non-Opus candidates and Opus to detect unstable results.
The final recommendation uses the repeated results; a single unusually favorable
run cannot decide the winner.

## Hard Gates

A production recommendation must satisfy all of the following on every scored
run:

- whole-recipe nutrition: at least 95% of cases pass;
- sparse/no-recipe evidence: 20/20 rejected safely;
- visual provider calls: zero;
- corpus and prompt digests match the frozen references;
- at least 95% of cases return valid structured extraction output.

Models that miss a hard gate remain visible in the report but cannot win.
Nutrition failures caused solely by the shared deterministic USDA stage are
reported separately so they do not masquerade as a model-quality difference.

## Quality Ranking

Quality is compared lexicographically rather than blended with price:

1. valid structured extraction rate;
2. whole-recipe nutrition pass rate;
3. ingredient name-and-quantity micro recall;
4. ordered instruction-phrase micro recall;
5. explicit cook-time accuracy;
6. run-to-run consistency across the repeated finalists.

This order reflects the cooking experience: a complete usable recipe matters
first, followed by accurate mise en place, method, and timing. The report will
show every component instead of hiding tradeoffs inside one arbitrary weighted
score.

If two passing models are within one percentage point on each structural metric
and have the same structured-output success rate, treat their quality as
comparable. Break that tie by lower measured end-to-end API cost, then lower
median case latency, then lower p95 case latency.

## Measurements and Artifacts

The evaluator will accept an explicit model ID so each invocation is auditable.
Each result artifact will include:

- model ID, prompt version, corpus identity, label, and run timestamp;
- per-case elapsed time and success/failure;
- extraction and verification usage and reported cost where available;
- aggregate valid-output, nutrition, sparse-safety, and structural metrics;
- total cost, cost per successful case, median latency, and p95 latency;
- zero as the visual-provider-call count.

A separate comparison command will read completed JSON artifacts, reject
incompatible corpus/prompt runs, aggregate the frozen metrics, and print both a
machine-readable comparison file and a concise ranked table. API keys remain
environment-only and must never appear in commands, artifacts, logs, or commits.

## Failure Handling

Provider, timeout, schema, and token-limit failures are case failures, not silent
omissions. The runner continues to the next case and records the error class
without sensitive response bodies. A failed candidate may be rerun only as a
new labeled attempt; existing evidence is never overwritten.

If a provider does not actually honor strict structured output despite advertising
support, that behavior is part of its reliability score. The protocol and prompt
stay fixed rather than being tuned around one provider.

## Affected Components

- `Backend/scripts/eval_extraction.py`: explicit model selection, complete timing
  and usage capture, aggregate benchmark fields, and collision-safe output.
- `Backend/scripts/compare_extraction_models.py`: compatible-run validation,
  structural aggregation, finalist comparison, and ranked JSON/table output.
- `Backend/tests/unit/scripts/`: argument, aggregation, ranking, and safety tests.
- `Backend/docs/verification/`: final measured bake-off report and recommendation.

Production defaults do not change during the benchmark. Selecting and deploying
a winning model is a separate, explicit change after reviewing the evidence.

## Verification

Implementation follows red-green-refactor. Run the new narrow evaluator tests,
the existing evaluation and extraction tests, Ruff, mypy, and `git diff --check`
before committing. Live result files are validated by the comparison command and
spot-checked against raw case data before the recommendation is written.
