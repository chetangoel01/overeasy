# Text-Only Accuracy Pipeline Design

## Purpose

Make recipe imports as accurate as the available written evidence permits,
prove at least 95% held-out per-recipe accuracy for calories and the three
primary macros together, and handle nearly empty social posts without ever
analyzing a video frame, thumbnail, or photo.

The previous three-cent ceiling is removed. Provider cost remains observable
and shared results remain cached, but cost must not cause evidence truncation,
shortened transcription, skipped verification, or selection of a less
accurate model.

## Success criteria

### Nutrition

A reference recipe passes only when all of these are true:

- stated servings are correct;
- calories per serving are within 10% of the reference;
- protein, carbohydrate, and fat grams per serving are each within the larger
  of 2 grams or 10% of the reference; and
- the result is based on creator-stated nutrition or auditable ingredient
  calculations, not an unsupported language-model estimate.

At least 95% of the held-out, sufficiently specified reference corpus must
pass as whole recipes. Reporting no nutrition does not count as a pass on that
corpus.

### Sparse sources

Sparse-source fixtures pass only when the pipeline either finds a trustworthy
written recipe belonging to the source creator or returns an explicit
insufficient-evidence result. It must never substitute an unrelated recipe for
the same dish, invent missing quantities, or invoke visual analysis. This
safety gate must pass 100% of its cases.

### Other recipe fields

Cook time, servings, ingredients, and steps retain their evidence provenance.
Stated values outrank estimates. Contradictions are surfaced for review rather
than silently resolved, and unsupported values remain absent.

## Considered approaches

### Prompt-only extraction

One model could continue producing the entire recipe, including nutrition.
This is compact but cannot make nutrition auditable, and a second wording of
the same prompt does not turn an estimate into evidence.

### Two language models

An extractor and reviewer could challenge one another. This is useful for
structural checking, but both can repeat the same nutrition hallucination.

### Grounded calculation with targeted verification

The selected approach uses models for text interpretation and evidence
reconciliation, while deterministic code calculates nutrition from creator
facts or authoritative food-composition records. A verifier only revisits
fields that fail evidence or consistency checks. This separates semantic work
from arithmetic and makes failures explainable.

## Architecture

### 1. Text-only acquisition

The acquisition ladder accepts:

- post title, description, creator identity, and other textual metadata;
- creator or platform captions;
- audio transcription, because downstream extraction receives only its text;
- platform-published sticker or accessibility text already present in page
  data;
- pages directly linked by the creator; and
- bounded web-search results and fetched written pages.

The production runtime will not construct a frame sampler, video-vision
provider, or thumbnail observer. It may still download and store a thumbnail
for display, but thumbnail bytes never enter a model. Provider-supplied visual
analysis is also disabled. Tests assert this at both configuration and call
boundaries.

Audio transcription uses a technical size and duration limit only to protect
worker stability. It no longer uses a cost-derived five-minute limit.

### 2. Sparse-source search

When title, description, transcripts, and directly linked documents do not
contain a usable recipe, a search component issues targeted queries based on
creator identity, exact dish title, canonical URL, and distinctive caption
phrases. It can make multiple searches and inspect several candidates.

A candidate becomes evidence only after identity checks connect it to the
creator or source post and its page contains recipe quantities and method.
Generic recipes, scraped copies without attribution, search snippets alone,
and pages for a merely similar dish are rejected. Search and fetch failures
degrade to insufficient evidence rather than a fabricated recipe.

### 3. Evidence extraction

The primary structured extraction produces:

- title and description;
- servings and whether they were stated or estimated;
- preparation, cooking, and total time with source basis;
- ingredients with verbatim quantity, normalized amount and unit,
  preparation, and evidence provenance;
- ordered steps, source timing when supplied by transcript text, ingredient
  references, and stated timers; and
- creator-stated nutrition, when present, with its serving basis and
  provenance.

The model does not invent nutrition. If the creator did not state it, the
nutrition field remains absent until the calculator runs.

### 4. Grounded nutrition calculation

Creator-stated nutrition has first priority when its serving basis matches the
extracted yield. Otherwise a nutrition service resolves each quantified
ingredient against USDA FoodData Central, using the ingredient name,
preparation state, normalized amount, and USDA portion weights. Matches and
nutrient values are cached.

The calculator sums calories, protein, carbohydrate, and fat for the complete
recipe, then divides by the supported serving count. It rejects ambiguous food
matches, missing nontrivial ingredient quantities, incompatible units, and
unknown yields. It also checks that calories are broadly consistent with
`4 * protein + 4 * carbohydrate + 9 * fat`, allowing for fiber, alcohol,
organic acids, and label rounding.

Nutrition records carry their basis (`creatorStated`, `usdaCalculated`, or
`unknown`) plus the ingredient matches used, so a later audit can reproduce
the result.

### 5. Targeted verification

A separate verifier receives the structured recipe and the exact text spans
supporting fields that failed deterministic checks. It looks for:

- conflicting amounts or serving counts;
- unit and fraction mistakes;
- missing ingredients mentioned by method text;
- ingredients assigned to the wrong sub-preparation;
- cook-time arithmetic contradictions;
- unsupported steps; and
- nutrition serving-basis mismatches.

It returns field-level corrections with citations to supplied evidence. Only
disputed fields are retried, preserving good work and making the verifier less
likely to rewrite facts that were already correct.

### 6. Cost and caching

There is no per-share rejection threshold. Every provider response records its
reported USD cost where available, token or audio usage, model, operation, and
job. Providers that bill in proprietary credits retain those units alongside
an optional configured USD conversion.

Canonical public shares still use the existing claim-coalesced extraction
cache. Search results, fetched pages, USDA matches, and verified nutrition are
also cacheable by stable identity and revision. Re-import continues to bypass
stale recipe output while reusing safe upstream evidence where appropriate.

## Data flow

1. Resolve the canonical source and collect free textual evidence.
2. Transcribe audio when published captions are absent or incomplete.
3. Fetch creator-linked pages.
4. If coverage remains sparse, search for and validate creator-authored pages.
5. Refuse the import when no text supports at least one ingredient and one
   ordered step.
6. Extract the structured recipe and creator-stated nutrition.
7. Resolve USDA ingredients and calculate missing nutrition.
8. Run deterministic consistency checks and targeted verification.
9. Review disputed fields once more, then persist the recipe, provenance,
   uncertainties, and usage.

## Error handling

- Missing or failed transcription continues to later text rungs.
- Search unavailability falls back to already collected text.
- USDA unavailability preserves creator-stated nutrition but never triggers an
  LLM nutrition guess.
- Ambiguous ingredient matches or incomplete quantities yield missing
  calculated nutrition and an actionable uncertainty.
- Malformed model output can be repaired or retried without discarding
  already validated evidence.
- No-evidence sources finish as needs-review/insufficient-evidence rather than
  a plausible-looking inferred recipe.

## Evaluation

The evaluator will replace completeness-only scoring with versioned fixtures
and reference answers. It will keep tuning and held-out partitions separate
and report:

- whole-recipe nutrition pass rate;
- field-level calorie and macro errors;
- serving accuracy;
- ingredient precision/recall with quantity and unit checks;
- cook-time error;
- ordered-step coverage and unsupported-step rate;
- sparse-source refusal/search correctness;
- count of visual-provider calls, required to be zero; and
- provider usage and cost distributions for observability.

Prompt or model changes cannot ship under an existing cache version. A
milestone is complete only after the held-out nutrition gate reaches 95%, the
sparse and zero-vision gates reach 100%, focused tests pass, the complete
backend suite passes, and the verification record contains fresh commands and
results.

## Affected components

- acquisition coverage and provider chain;
- free linked-document acquisition and new search integration;
- worker runtime configuration;
- structured extraction schema, prompt, and review logic;
- USDA matching and nutrition calculation;
- provider usage accounting;
- extraction evaluation corpus, scorer, and reports;
- deployment defaults and operator documentation.
