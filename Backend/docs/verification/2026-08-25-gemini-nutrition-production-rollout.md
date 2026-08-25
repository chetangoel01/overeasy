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
- Production revision `d54d19385a28d0a37dd4e6d82b5872806d1801dd` passed the deploy health gate, Caddy validation, public liveness, and public readiness.
- A fresh disposable guest submitted the supplied Ian Kyo TikTok link through the public VPS. It reached `needsReview` as **10-Minute Chili Garlic Noodles** with 2 estimated servings, 12 ingredients, 6 steps, and estimated per-serving nutrition of 839.8 calories, 27.6 g protein, 76.4 g carbohydrate, and 46.8 g fat.
- The generic physical-device Release build reached signing, then stopped because the Mac has no valid code-signing identity or active Apple Developer account session. The paired iPhone 17 Pro also reported its developer tunnel unavailable. Build, install, and launch remain pending an unlocked Mac, refreshed Xcode account/certificate, and connected unlocked phone.

No credentials are recorded in this document. Local release secrets remain in ignored, owner-readable configuration; VPS secrets remain in the root-owned environment file.
