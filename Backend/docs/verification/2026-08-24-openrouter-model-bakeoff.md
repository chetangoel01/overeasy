# OpenRouter Recipe Extraction Model Bake-Off

## Outcome

`google/gemini-3.7-flash` is the best new challenger. Across two clean
80-recipe runs, 3.7 kept 100% schema validity, 95% whole-recipe nutrition
accuracy, 100% stated cook-time accuracy, and 67.5–70% exact ordered-step
phrase recall. The protocol-compatible historical 3.6 run scored 73.75% on
that step probe, so the bake-off alone did not establish a head-to-head win.

On 2026-08-24 the user explicitly selected 3.7 as Ladle's quality-first live
default despite that unresolved historical comparison. This is a product
choice for live validation, not a claim that the measurements prove 3.7 beats
3.6 on step preservation.

Gemini 3.7's average reported run cost was $1.2403, or about $0.0155 per
successful recipe, with a 7.3-second median latency. The historical 3.6
artifact recorded at least $1.3038 of extraction cost but predates complete
verification-cost and latency capture, so its end-to-end cost is not directly
comparable.

Claude Opus 5 is the quality-first fallback when Gemini is unavailable. It was
schema-reliable but reproduced only 20% exact ordered-step phrase recall while
costing at least $8.20 per run. Grok 4.6 was also schema-reliable, but its 15%
step recall, $3.53 cost, and 63.4-second median made it strictly worse than
Gemini 3.7 for this source-faithful extraction task.

## Protocol

- Frozen prompt: `recipe-2026-08-24-v11`
- Frozen verified corpus: 80 public-government recipes (75 NHLBI, 5 USDA)
- Temperature: 0
- Evidence: text only; every scored run recorded zero visual-provider calls
- Safety: all 20 sparse-evidence cases had to pass
- Hard gates: at least 95% valid structured output, at least 95% nutrition,
  20/20 sparse safety, and zero visual calls
- Quality order: schema validity, nutrition, exact ingredient name/quantity
  recall, exact ordered-step phrase recall, then stated cook-time accuracy
- Price and latency were considered only after quality

Exact phrase recall is deliberate: Ladle needs instructions traceable to the
written source. Opus and Grok frequently produced polished paraphrases or added
connective wording. Those outputs could read well while weakening source
fidelity, so they did not receive credit for merely preserving the general
meaning.

## Final measured comparison

| Model | Clean runs | Gate | Valid | Nutrition | Ingredient | Steps | Cook time | Reported cost/run | Median | p95 |
|---|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Gemini 3.6 Flash (incumbent historical baseline) | 1 | PASS | 100% | 95% | 3.8% | 73.8% | 100% | at least $1.3038* | not recorded | not recorded |
| Gemini 3.7 Flash | 2 | PASS | 100% | 95% | 5.6% | 68.8% | 100% | $1.2403 | 7.3s | 16.1s |
| Claude Opus 5 | 2 | PASS | 100% | 95% | 5.0% | 20.0% | 100% | at least $8.20* | 24.4s | 37.1s |
| Grok 4.6 | 1 | PASS | 100% | 95% | 3.8% | 15.0% | 100% | $3.5274 | 63.4s | 110.4s |
| Qwen3 235B 2507 | 1 | FAIL | 22.5% | 21.2% | 0% | 61.1%** | 100% | $0.0483* | 3.1s | 26.7s |

\* Provider cost reporting was incomplete, so the value is a lower bound and
was excluded from price-based selection. The 3.6 aggregate was reconstructed
from its saved case-level fields because that artifact predates the new
`benchmark` summary.

\** Qwen step recall is measured only across its 18 schema-valid cases. Sixty-two
of 80 cases failed structured output, so it is not a viable candidate.

Gemini's individual clean runs scored 70.0% and 67.5% on ordered-step phrases,
with costs of $1.2401 and $1.2405. Opus scored exactly 20.0% on both clean runs.
The repeat evidence therefore supports a stable, material 3.7 advantage over
the new challengers, but not over the incumbent on step preservation.

## Operational failures and excluded runs

- `moonshotai/kimi-k3` passed the one-case preflight but its full run blocked
  reading an upstream response for more than an hour and produced no artifact.
  It was stopped and classified as an operational failure.
- `deepseek/deepseek-v4-pro-0813` passed a confirmation preflight after an
  initial failure. Its full run produced invalid output on cases 1, 7, 11, 13,
  and 19. Five invalids cap an 80-case run at 93.75%, below the 95% gate, so it
  was stopped early.
- The first Gemini repeat encountered a short HTTP 429 burst on six consecutive
  cases and was excluded. That exposed a client gap: structured extraction did
  not retry rate limits. The client now honors numeric `Retry-After` values and
  otherwise uses bounded 2/4/8-second backoff. A fresh repeat then passed 80/80.
- A Grok repeat was stopped after eight valid cases when the user ended further
  live spend. The completed 80-case Grok run remains valid evidence, but Grok
  does not have repeat evidence.

These deviations do not change the challenger result: Gemini 3.7 has two clean
runs, Opus has two controls, and 3.7 leads Opus by 48.8 percentage points in
aggregate ordered-step recall while also costing substantially less and
returning faster. They also do not establish that 3.7 beats Gemini 3.6.

## Cost accounting

The sum of costs reported in saved bake-off artifacts is $23.8568. The OpenRouter
account showed roughly $25 total; the difference is consistent with aborted
Kimi, DeepSeek, and Grok calls plus provider attempts that returned no usage
metadata. No further live model calls were made after the user stopped spend.

## Product behavior and affected components

- `ladle/config.py` and `.env.example` use the user-selected
  `google/gemini-3.7-flash` extraction and verification default.
- `ladle/extraction/openrouter.py` recovers boundedly from HTTP 429 responses.
- The evaluator records per-case latency, provider usage/cost, hard-gate
  summaries, and flushed progress markers.
- The comparison module validates compatible artifacts, groups repeats, applies
  gates, ranks quality lexicographically, and selects value only within the
  quality-equivalence band.

Deployments can still choose another model through `LADLE_OPENROUTER_MODEL_ID`.
A claim that 3.7 outperforms 3.6 still requires a fresh, repeated head-to-head
run.

## Evidence artifacts

Generated evidence is intentionally ignored by Git and remains under
`Backend/.eval-cache/results/`:

- `2026-08-24-bakeoff-round1-gemini-3.7-flash.json`
- `2026-08-24-bakeoff-finalist-repeat2-gemini-3.7-flash.json`
- `2026-08-24-v11-held-out-regression.json`
- `2026-08-24-bakeoff-round1-claude-opus-5.json`
- `2026-08-24-bakeoff-finalist-repeat-claude-opus-5.json`
- `2026-08-24-bakeoff-round1-grok-4.6.json`
- `2026-08-24-bakeoff-round1-qwen3-235b-2507.json`
- `2026-08-24-bakeoff-final-comparison.json`

The throttled Gemini artifact is retained for operational diagnosis but is not
included in the final comparison.

## Verification

- Focused evaluator, comparator, OpenRouter, and configuration tests: 96 passed
- Full backend pytest suite: 644 passed, 5 skipped
- Ruff: all checks passed
- mypy: no issues in 119 source files
- `git diff --check`: clean before commit
