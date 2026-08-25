# Nutrition-First Recipe Pipeline Design

## Purpose

Nutrition is a required part of a useful Ladle recipe. A recipe may still be
returned when nutrition enrichment fails, but it cannot be marked ready while
calories and primary macros are silently absent. The pipeline must make a
reasonable, visible estimate when a creator omits servings or quantities rather
than treating missing facts as a reason to skip nutrition entirely.

## Confirmed failure mode

The extraction prompt deliberately returns `nutrition: null` so model arithmetic
cannot masquerade as sourced nutrition. Deterministic code then parses explicit
creator panels or calls USDA. The current USDA calculator exits immediately for
estimated servings and returns `None` when any material ingredient has no unique
food match or supported mass conversion. It exposes no blocker. All five live
recipes therefore stored `nutrition: null`, and both validation HTML pages omit
nutrition rendering even when a future result contains it.

## Real-link feasibility probes

Five Gemini 3.7 Flash normalization calls used preserved evidence from the exact
TikTok and Instagram links supplied by the user. They did not reacquire media or
ask the model to calculate calories.

| Recipe | Existing yield | Normalized yield | Confidence | Important result |
| --- | ---: | ---: | ---: | --- |
| French Onion Pasta | 4 estimated | 4 | 0.85 | Converted onions, cloves, pasta range, and cheeses to mass. |
| Hoisin Garlic Noodles | 1 estimated | 4 | 0.95 | Corrected the implausible yield and inferred 15 ml sauté oil. |
| Chili Garlic Noodles | 2 stated | 2 | 0.95 | Converted “2 portions” to an estimated 200 g dry noodles. |
| Chicken & Gnocchi | 2 stated | 2 | 1.00 | Preserved the explicit yield and treated deglazing liquid as optional. |
| Cucumber Ribbon Salad | 1 estimated | 4 | 0.70 | Corrected the side-dish yield and exposed the mirin-versus-water choice. |

The five successful calls cost about $0.03720 in total. One transient 429 was
diagnosed as an upstream/provider rejection: the account retained credit and
the key had no configured cap. Each case was allowed at most one retry.

## Chosen approach

Use a specialized model normalization pass followed by deterministic USDA
calculation.

Pure model-generated calories would maximize coverage but weaken auditability.
Strict USDA-only calculation is auditable but produced zero nutrition panels on
the live set. The hybrid keeps Gemini on the task it handled well in the probes:
interpreting recipe yield, ordinary kitchen measures, missing amounts, and
USDA-friendly food names. USDA remains the source of calories and macros.

## Data flow

1. Acquire real creator evidence and perform the existing recipe extraction.
2. Parse any explicit creator nutrition panel; creator-stated values always win.
3. Run the Gemini 3.7 normalization pass for recipes without a complete creator
   panel. Give it the creator evidence plus the reviewed recipe template.
4. Return one record per ingredient keyed by ingredient index, including a
   simple USDA search term, normalized grams, whether the value
   was inferred, and a concise rationale. Return yield, confidence, rationale,
   and a bounded list of assumptions.
5. Preserve creator-stated amounts and yield. Model values fill missing
   quantities, convert count/volume measures, and replace only an explicitly
   estimated yield when culinary evidence indicates a more realistic value.
6. Calculate whole-recipe nutrition from USDA and divide by the stated or
   visibly estimated yield. Store per-serving calories, protein, carbohydrate,
   and fat with `is_estimated=true`, a USDA basis, cited FDC identifiers, the
   serving confidence, and the model assumptions in the evidence text.
7. Display per-serving nutrition as the focal value and derive whole-recipe
   totals from the per-serving panel and yield. Show the stated/estimated yield,
   confidence, and assumptions beside it.

## Guardrails

- The normalization model never supplies calories or macros.
- Stated servings and ingredient amounts cannot be overwritten.
- Every inferred quantity must carry a rationale; every estimated yield must
  carry confidence and a rationale.
- Water and genuinely to-taste seasonings may be excluded as nutritionally
  immaterial, but the exclusion is recorded.
- Alternative ingredients such as “mirin or water” require an explicit selected
  assumption because they can materially change calories.
- The USDA result remains all-or-nothing for energy-bearing ingredients after
  normalization; partial totals must not look complete.
- A normalization or USDA failure returns a typed blocker, forces
  `needsReview`, and remains visible in the validator instead of silently
  storing `nutrition: null` on a ready recipe.
- Model normalization receives at most one retry for a transient provider error.

## Components

- Add structured normalization request/response models and an injectable
  normalizer protocol.
- Add a Gemini/OpenRouter implementation pinned to
  `google/gemini-3.7-flash`.
- Extend nutrition calculation to accept a normalized estimated yield and to
  return typed ingredient-level failure reasons.
- Integrate normalization between creator-fact parsing and USDA calculation in
  both the live worker and evaluation/validator pipeline.
- Add calories and primary macro panels, estimate labels, confidence, evidence,
  and blockers to both HTML artifacts.
- Reprocess all five preserved real-link recipes through normalization and USDA
  without reacquiring or re-extracting the videos.

## Verification

- Write failing unit tests before each behavior change: protected stated facts,
  inferred yield, ingredient-index mapping, schema failures, one-retry behavior,
  estimated-yield calculation, typed USDA blockers, and HTML nutrition output.
- Keep provider tests deterministic with injected clients; no paid calls in the
  unit suite.
- Run the focused extraction, nutrition, validator, and worker tests, followed
  by full backend pytest, Ruff, mypy, and `git diff --check`.
- Run the five preserved real-link cases once against the approved normalizer
  and USDA path. Report per-serving and whole-recipe values, confidence,
  assumptions, latency, and spend; do not invent labeled reference answers.

## Implementation record

- The normalization boundary now has a strict schema, protects stated facts,
  requires complete material-ingredient coverage, persists explicit exclusions,
  and records inferred quantity uncertainty.
- The OpenRouter adapter is pinned by default to Gemini 3.7 Flash, requests no
  nutrient totals, records usage, and permits one retry only for HTTP 429.
- The USDA calculator now accepts `estimatedFromYield` and exposes stable
  ingredient-level blockers for missing or ambiguous food matches, missing
  mass, inconsistent nutrient records, and invalid yield. Its compatibility
  method still returns `None` for callers that have not adopted diagnostics.
- The enrichment service gives creator panels precedence, composes model
  normalization with deterministic USDA arithmetic, appends serving confidence
  and assumptions to the audit evidence, and converts either boundary's failure
  into a visible `nutrition` uncertainty with `needsReview` status.
- Production imports, evaluation, and the localhost validator now use that same
  enrichment service. Live construction requires both provider credentials,
  fake imports remain free, validator progress exposes normalization and USDA
  stages, and reported usage includes the normalization call and cost.
- Both HTML artifacts now lead with per-serving calories and primary macros,
  derive a whole-recipe calorie total from yield, show the nutrition evidence,
  and render a prominent blocker when no complete panel exists. Local browser
  checks passed at 1280 px and 390 px without horizontal overflow.
