# A curated table for the foods USDA does not have

Date: September 7, 2026

**Tier 1** of issue #37, stacked on
[Tier 0](2026-09-07-nutrition-no-coverage-floor.md) (PR #104), which made a
skipped ingredient survivable and recorded every skip. This closes the skips
that will never be closed by better searching.

## Purpose

Tier 0 is honest about what it cannot cost, and on this library that is a spice
on nearly every South Asian recipe. No query-layer fix reaches these: USDA's
best answer for `garam masala` is `SMART SOUP, Indian Bean Masala` (171181,
57 kcal) and for `curry leaves` it is `Drumstick leaves, raw` (168416), a
different plant. The record does not exist to be found.

So the table. Values estimated per 100 g, each row stating how its numbers were
reached, and every row read in a diff before it merges. The review is the only
safeguard — there is no laboratory behind these figures — which is why the
basis is stored beside the numbers in the data file rather than in a commit
message nobody re-reads.

## Decisions in force

From issue #37, "Decisions, 2026-09-07":

1. **Curated, checked in, LLM-estimated, human-reviewed.** Not a provider, not
   a service, not a setting. Reference data in the repository.
2. **The curated entry wins when it exists**; otherwise USDA; otherwise the
   ingredient is skipped as before.
3. **A curated match is a real match.** It is costed like any other, and it
   does not put the `approximate` marker on the recipe.
4. **Decomposing blends into components is not pursued.** Garam masala is one
   row, not six ingredients invented by a model at extraction time.
5. **Grown from real misses only.** The seed set is what testing already
   showed missing; the ops panel (sibling PR) is the backlog for the rest.

## The table

`Backend/ladle/nutrition/curated_foods.json`. Five rows. Per 100 g:

| Food | kcal | Protein | Carb | Fat | Fibre | Basis |
|---|---:|---:|---:|---:|---:|---|
| garam masala | 292.7 | 10.2 | 63.0 | 10.7 | 32.1 | Unweighted mean of the six USDA SR Legacy spices the blend is built from: coriander seed (170922, 298 kcal), cumin seed (170923, 375), pepper black (170931, 251), cinnamon ground (171320, 247), cardamom (170919, 311), cloves ground (171321, 274). Proportions vary by house; the six span 247–375 kcal, which bounds the error. |
| curry leaves | 108 | 6.1 | 18.7 | 1.0 | 6.4 | The published Indian food-composition figure for fresh *Murraya koenigii* leaves. **The least-backed row**: no laboratory record supports it and it is not a blend that can be averaged from one. Recipes use 1–15 g, so a 30% error is a few kcal on a dish. |
| ginger garlic paste | 114.5 | 4.09 | 25.45 | 0.63 | 2.05 | Equal parts of the two USDA SR Legacy records it is made from: Ginger root, raw (169231 — 80 kcal) and Garlic, raw (169230 — 149 kcal). Jarred pastes are usually thinned and salted; this is the plain 1:1 fresh blend, which is what a recipe means. |
| tamarind paste | 191.2 | 2.24 | 50.0 | 0.48 | 4.08 | USDA Tamarinds, raw (167763 — 239 kcal) scaled by 0.8 for the water a commercial paste is let down with. **The 0.8 is the one outright guess in the table**: jars run from near-neat pulp to heavy concentrate, with labels between roughly 150 and 240 kcal. |
| italian seasoning | 281.8 | 11.5 | 61.0 | 8.5 | 40.1 | Unweighted mean of the six USDA SR Legacy dried herbs in the blend: oregano (171328, 265 kcal), basil (171317, 233), thyme (170938, 276), rosemary (171333, 331), marjoram (170928, 271), sage ground (170935, 315). |

Every panel passes the calculator's own Atwater consistency check
(`_consistent`), which a test pins — an estimate that fails it means the macros
and the calories were guessed independently rather than from one source.

Aliases, one explicit list per row:

| Food | Answers to |
|---|---|
| garam masala | garam masala powder, garam masala spice blend, garam masala spice mix, ground garam masala |
| curry leaves | curry leaf, fresh curry leaves, kadi patta, kariveppilai, sweet neem leaves |
| ginger garlic paste | ginger-garlic paste, garlic ginger paste, adrak lehsun paste, ginger and garlic paste |
| tamarind paste | tamarind concentrate, tamarind pulp, tamarind puree, tamarind extract, imli paste |
| italian seasoning | italian herb mix, italian herbs, dried italian herbs, italian herb seasoning, italian herb blend |

Each row also answers to its own name. Comparison is on lowercase alphanumeric
words, so case, hyphens and punctuation do not matter and nothing else does.

Portions are carried per row for the units a recipe uses — 1 tsp of garam
masala is 2.5 g, of italian seasoning 1 g, of ginger-garlic paste 6 g; curry
leaves are also weighed by the leaf (0.3 g) and the sprig (3 g). They are only
consulted when the normalizer could not put a gram figure on the ingredient
itself.

### The evidence for each row, and what was left out

Every row points at a recorded miss:

- **garam masala** — the August 31 triage probe (`docs/plans/2026-08-31-ui-feedback-triage.md`,
  "Best USDA match: SMART SOUP, Indian Bean Masala — absent") and recipe 8
  (Egg Bhurji) of the September 2 dry run.
- **curry leaves** — the same probe ("Drumstick leaves, raw — absent"), the
  `curry leaf → beef curry` weak match, and recipe 22 (Madras Curry) of the
  dry run.
- **ginger garlic paste** — the same probe ("Almond paste — absent"). Since the
  September 1 query fix it resolves to `Ginger root, raw` alone, which is not a
  miss any more but silently drops the garlic; the curated row corrects it.
- **tamarind paste** — named in issue #37 as one of the four known gaps.
- **italian seasoning** — recipes 14 and 26 of the September 2 dry run
  (`Italian herb mix`, `Italian seasoning`), skipped as `foodNotFound`.

**Deliberately not added.** The dry run's uncounted set is wider than the
absent foods, and the rest of it is the relevance gate refusing records USDA
does have. A curated row there would paper over a matching bug and freeze a
hand-written estimate in front of a laboratory record:

| Skipped in the dry run | Why not curated |
|---|---|
| `tomato` (recipe 6, 123 g), `lentils`, `pancetta`, `Rice vinegar` | Ordinary foods with USDA records; the matching layer failed to reach them. |
| `green cardamoms` (recipe 16) | USDA has `Spices, cardamom` (170919). The query carries "green", which the relevance gate refuses. |
| `ghee` (recipe 8) | **A probe run for this PR shows USDA has it**: `Ghee, clarified butter` (2710168, 876 kcal) and `Butter, Clarified butter (ghee)` (171314, 900). The September 2 skip is a matching failure, not an absence — worth a separate look. |
| plain `tamarind` | USDA answers it correctly with `Tamarind` (2709269) and `Tamarinds, raw` (167763), both 239 kcal. Only the paste is missing, so `tamarind` is **not** an alias of the curated row. A test pins that. |

If the owner would rather the paste figure won for a bare `tamarind`, adding
one alias does it — but it would displace a real record with an estimate.

The probes behind this table were run against FoodData Central's public API
with `DEMO_KEY`, searching the same three generic data types the client asks
for (Foundation, SR Legacy, Survey). The fdc ids and figures in the basis
strings are from those responses, not from memory.

## What changed

### The curated source (`Backend/ladle/nutrition/curated.py`)

`CuratedFood` is one reviewed estimate; `CuratedFoodTable` indexes entries by
every name they answer to and refuses two entries claiming the same name;
`curated_food_table()` parses the JSON once per process. `CuratedFood.nutrients()`
returns a `FoodNutrients`, so nothing downstream can tell a curated record from
a provider's.

`FoodNutrients.data_type` gains `"Curated"`. It is deliberately absent from
`_DATA_TYPES`, so it is never asked for in a search and `_parse_food` rejects
any USDA payload claiming it: the only records carrying it are the ones this
repository wrote by hand. `id` is not a FoodData Central identifier — the
9000000 block is Ladle's own, and the evidence line names the source and the
food rather than the number, so it never reaches a screen.

### Why it is a rung and not a `FoodDataSource`

The brief's letter says "a curated source that answers before USDA", and
`FoodDataSource` is the obvious shape. It does not work. `_usable_food` runs
every candidate through `_relevant(usda_search_term, description)`, and the
search term is the field the normalizer *rewrites*: it emits `ginger root raw`
for ginger-garlic paste, which shares one stem of three with the description
`ginger garlic paste` and is refused. The table is keyed to `ingredient.name`,
the one field no model rewrites. `usda_search_term` is tried as a second key,
after the name, because it costs nothing and sometimes carries the plainer
phrasing.

### The ladder (`Backend/ladle/nutrition/calculator.py`)

`NutritionCalculator` takes `curated` beside `source` and `fallback`, and
`_matched` asks the table first.

**A curated row wins outright.** If it matches but the ingredient cannot be
weighed, the failure is `missingMass` and the ingredient is skipped — it does
*not* fall through to USDA. Falling through would spend a search on the
ingredient USDA is known to fail, and would file the skip as `foodNotFound`,
which puts the food on the ops panel's list of rows to add to a table it is
already in. `missingMass` names the real fix: a portion.

`_matched` now returns the evidence citation rather than a source name, because
"USDA FDC 9000001" for a curated record would be a lie. The USDA and fallback
citations are byte-identical to before; a curated one reads
`Ladle curated garam masala`. A recipe with both says
`USDA FDC 171077, Ladle curated garam masala`.

### Composition

`worker/runtime.py` and `scripts/refresh_recipe_nutrition.py` pass
`curated=curated_food_table()`. There is no setting: the table is reference
data, it needs no key and no network, and a row only exists because a real miss
put it there. It is a constructor argument rather than a default so that the
tests which use `garam masala` as *the* unmatchable ingredient still say what
they mean.

No wire change, no migration, no service change. A curated match is an ordinary
costed ingredient: no skip row, no note, no marker.

## Affected components

- `Backend/ladle/nutrition/curated.py`, `curated_foods.json` — new
- `Backend/ladle/nutrition/calculator.py` — the curated rung, the evidence
  citation, `Curated` in the data-type priority
- `Backend/ladle/nutrition/usda.py` — `Curated` in `FoodDataType`
- `Backend/ladle/worker/runtime.py`, `Backend/scripts/refresh_recipe_nutrition.py`
- `Backend/tests/unit/nutrition/test_curated.py` — new
- `Backend/tests/unit/nutrition/test_calculator.py`

## Tests

New, in `test_calculator.py`:

- a curated ingredient is costed and USDA is never asked (`usda.calls` is
  exactly the other ingredient);
- a curated match leaves `approximate` false while `is_estimated` stays true;
- `Kadi Patta` and `curry leaves` produce the same number and the same
  evidence;
- an ingredient absent from the table still reaches USDA;
- a curated ingredient measured in "handfuls" is skipped as `missingMass` with
  no USDA call.

New, in `test_curated.py` — the mechanical half of the review:

- the shipped table loads, and every entry has a basis, an alias and five
  non-negative nutrient figures;
- every panel passes `_consistent`;
- every portion has a positive amount and gram weight;
- the entry list is exactly the five seeded foods, so a sixth cannot arrive
  without a reviewer noticing;
- aliases match through case and punctuation, an unknown name returns nothing,
  bare `tamarind` returns nothing;
- two entries claiming one name raise.

Red first: without `ladle/nutrition/curated.py` both files fail to import, and
with the module present but the rung disabled the four calculator tests fail on
their assertions.

## Verification

From `Backend/`, with Docker running:

```
uv run pytest tests/unit/nutrition -n0    108 passed
uv run pytest                             943 passed
uv run ruff format --check .              346 files already formatted
uv run ruff check .                        All checks passed!
uv run mypy --strict ladle                 no issues found in 128 source files
```

Not exercised: `scripts/refresh_recipe_nutrition.py` needs a live database and
provider keys. Its change is one constructor argument, by inspection.

## Not done here

- **No ops-dashboard change.** A sibling PR adds the misses panel; this PR is
  the other half of the loop and they do not touch the same files.
- **No client change.** Nothing new crosses the wire.
- **No backfill.** Recipes already stored with a skip row for garam masala keep
  it until `scripts/refresh_recipe_nutrition.py --apply` re-runs enrichment,
  the same deploy step Tier 0 already needs. Until it runs, these five foods
  stay on the panel and the recipes stay marked approximate.
- **No decomposition and no second provider**, per the decisions above.
