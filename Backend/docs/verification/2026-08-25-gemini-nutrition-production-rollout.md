# Gemini Nutrition Production Rollout

## Purpose

Deploy the quality-first recipe flow to the Ladle VPS and make the iOS release build use it. The flow uses Gemini 3.7 Flash for extraction and quantity normalization, then USDA data for calories and macros.

## User-visible behavior

- TikTok and Instagram imports can fall back to OpenRouter search when direct media metadata is incomplete.
- Missing yield and ingredient amounts are estimated before nutrition calculation.
- Imported recipes include an estimated serving count and per-serving calories/macros when sufficient food evidence exists.

## Production incident and fix

The first VPS smoke import reached the new `openrouterSearch` acquisition rung successfully, then failed while recording the provider result. The bounded metrics registry did not include that new provider name, so it raised `ValueError`; the worker surfaced the exception as `networkUnavailable`.

`openrouterSearch` is now an explicitly allowed provider metric label. A regression test records and renders that exact label so future acquisition rungs cannot silently reintroduce the crash.

## Affected components

- `Backend/ladle/observability/metrics.py`
- `Backend/tests/unit/observability/test_metrics.py`
- VPS API and worker deployment
- iOS release configuration and on-device build

## Verification

- Regression test: red on the missing label, green after the allowlist update.
- Backend: 691 passed, 5 skipped; Ruff passed; mypy passed across 121 source files.
- Production health and live social-link import: pending post-deploy verification.
- Physical-device release build, install, and launch: pending final verification.

No credentials are recorded in this document. Local release secrets remain in ignored, owner-readable configuration; VPS secrets remain in the root-owned environment file.
