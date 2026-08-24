# Text-only extraction evaluation

## Purpose

This benchmark measures the complete textual recipe path: structured
extraction, creator-nutrition preservation or USDA calculation, targeted
verification, and normalization to whole-recipe calories, protein,
carbohydrate, and fat. It never decodes or submits a photograph, thumbnail,
video frame, or PDF image.

The nutrition gate is deliberately all-or-nothing per recipe. A case passes
only when the stated yield matches, calories are within 10%, all three macros
are within the larger of 2 g or 10%, and the result has the expected
`creatorStated` or `usdaCalculated` basis. Missing nutrition fails.

Stored nutrition describes `servingBasis` servings. Before scoring, the
evaluator calculates each whole-recipe value as:

```text
stored value × recipe servings ÷ nutrition serving basis
```

## Locked corpora

`text-only-tuning.json` contains 20 USDA CACFP six-serving recipes.
`text-only-held-out.json` contains all 75 recipes from the NHLBI *Keep the
Beat Recipes: Deliciously Healthy Dinners* publication plus five different
USDA CACFP recipes. No recipe identity or source URL crosses partitions.

The combined 100 nutrition cases cover metric and customary measures,
fractions, counts, multi-part recipes, explicit yields, preparation and cook
times, ingredient lists, and ordered directions. Nine cases intentionally
remove the published nutrition panel from model evidence—five tuning and four
held-out—so those cases require the production USDA calculator and must return
the `usdaCalculated` basis. Their hidden references still come from the
publisher's nutrition panel.

The held-out fixture also contains 20 synthetic sparse/no-match results. They
represent the final text state after search found no creator-authored recipe.
Every one must be refused by the production evidence gate. These cases test
safe refusal, not live search recall.

Each retained case records its source URL, retrieval date, attribution,
partition, expected nutrition basis, and license category. The recipe texts
are official federal publications and are classified as U.S. Government
works under [17 U.S.C. § 105](https://www.govinfo.gov/app/details/USCODE-2023-title17/USCODE-2023-title17-chap1-sec105).
The fixtures omit all photographs and agency seals. Source indexes are:

- [NHLBI Deliciously Healthy Dinners](https://www.nhlbi.nih.gov/resources/keep-beat-recipes-deliciously-healthy-dinners)
- [USDA CACFP standardized recipes](https://www.fns.usda.gov/tn/cacfp/standardized-recipes)

Corpus digests cover the canonical JSON encoding of `cases` and
`safetyCases`:

```text
tuning   3461ea84be082f52436c70e38537bda708ca1719de0e362f792da876a8063eee
held-out 7153942ffc57e90a979c8e988e9d784133580091ae36c04068677687404ccd9b
```

`scripts/build_evaluation_corpus.py` reproduces the fixtures from text made
with `pdftotext -layout`. It requires exactly 25 selected USDA recipe files and
finds exactly 75 NHLBI recipe records, which prevents a partial source
download from silently becoming a valid corpus.

## Integrity verification

Run the non-billed checks with:

```bash
cd Backend
.venv/bin/pytest tests/unit/evaluation/test_extraction.py -q
```

They validate schemas, minimum case counts, fixed digests, complete nutrition,
source/license metadata, unique identities, partition isolation, nutrition
basis coverage, and 20/20 production-gate refusals for sparse evidence.

## Model runs

The evaluator uses production clients directly and does not require the API,
database, Redis, or worker process. Supply the same secrets used by a live
worker:

```bash
cd Backend
LADLE_OPENROUTER_API_KEY=... LADLE_USDA_API_KEY=... \
  .venv/bin/python scripts/eval_extraction.py extract \
  --corpus tuning --label public-domain-v1-tuning
```

For Anthropic, set `LADLE_EXTRACTION_PROVIDER=anthropic`,
`LADLE_ANTHROPIC_API_KEY`, and `LADLE_USDA_API_KEY` instead. The evaluator
stores sanitized per-case predictions, failed fields, structure measurements,
extraction token counts and provider-reported USD cost, prompt/model/corpus
versions, sparse results, and a zero visual-call count under
`.eval-cache/results/`.

After tuning is complete, freeze the prompt and model, then run the held-out
partition once for a milestone version:

```bash
LADLE_OPENROUTER_API_KEY=... LADLE_USDA_API_KEY=... \
  .venv/bin/python scripts/eval_extraction.py extract \
  --corpus held-out --label public-domain-v1-held-out
```

The milestone passes only at 76/80 or better, 20/20 sparse safety, and zero
visual-provider calls. `--only` is for diagnosis and cannot establish the
milestone.

## Interpretation limits

This corpus isolates text interpretation and nutrition behavior with stable,
auditable references. It is not a measurement of TikTok, Instagram, or
YouTube availability, audio-transcription quality, creator-search recall, or
the distribution of ordinary social recipes. Those acquisition layers retain
their separate integration and provider tests. A 95% result here must be
described as held-out accuracy on this public-government-recipe corpus, not as
95% accuracy for every recipe shared from the internet.
