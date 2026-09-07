# A recipe is never voided for nutrition reasons

Date: September 7, 2026

Follows [the September 2 per-ingredient degrade](2026-09-02-nutrition-per-ingredient-fallback.md),
which introduced skipping one ingredient and a floor on how much of a recipe's
mass could go missing. This removes that floor, and stores what was skipped.

This is **Tier 0** of issue #37. The ops-dashboard panel and the curated table
are later PRs; what they need is recorded here.

## Purpose

The September 2 work stopped one unmatched ingredient costing a recipe every
calorie — unless the unmatched ingredients were heavy, in which case
`insufficientCoverage` blocked the recipe anyway. Dropping weak matches made
that set wider than it looks, so the floor was a second way to lose the whole
panel.

The decision on 2026-09-07 (issue #37, "Decisions, 2026-09-07") removes it.
Chetan's words: *"no voiding a recipe unless it's obviously and clearly not a
food video."* A stew where only the onion matched shows ≈ 120 cal, and that is
accepted — the marker carries the doubt, not the absence of a number.

## Decisions in force

1. **No coverage floor.** Whatever matched is totalled. The only whole-recipe
   failures left are the ones that exist for other reasons: the evidence gate,
   `invalidYield`, `noMaterialIngredients`.
2. **A recipe where nothing matched produces no block.** There is nothing to
   total. That is an empty result, not an error, and no "Nutrition enrichment
   blocked" note is written for it.
3. **Weak matches are unmatched.** Unchanged from September 2 and re-confirmed:
   an ingredient whose best candidate does not describe it is skipped, not
   costed. It is only worth restating because removing the floor is what makes
   the wider skip set harmless.
4. **The card shows the ≈ marker only.** Which ingredients, and why, lives on
   the nutrition sheet.
5. **Every skip is recorded server-side**, because the panel and the curated
   table both depend on the skips existing.

## What changed

### Calculator (`Backend/ladle/nutrition/calculator.py`)

`_require_coverage`, the `insufficientCoverage` code and the
`uncounted_mass_share_limit` constructor argument are gone, and with them
`Settings.nutrition_uncounted_mass_share_limit` (`config.py`) and its pass-through
in `worker/runtime.py` and `scripts/refresh_recipe_nutrition.py`.

`calculate_required` now returns `TemplateNutrition | None`. `None` means no
ingredient matched anything, so no total exists — the one empty case. Every
other outcome is a block built from whatever was costed, and
`TemplateNutrition.approximate` is set when the `uncounted` list is non-empty.

`estimated_grams` stays. Nothing is refused for a bad share any more, but how
much of a library goes uncounted is what says whether the curated table is
worth growing, and the refresh script still prints it.

### Service (`Backend/ladle/nutrition/service.py`)

`enrich` no longer has a coverage branch. A `None` from the calculator goes
through `_with_nutrition`, not `_blocked`: the recipe keeps its review status
and gains the same notes it would have had — one
`ingredients[i].nutrition` uncertainty per skipped ingredient, landing on the
row, plus the recipe-level `nutrition` summary ("1 of 12 ingredients not
counted: garam masala."). `_cleared` now also empties `nutrition_skips`, so a
re-run that finally matches an ingredient stops reporting it.

### The contract

One new field: `NutritionDTO.approximate: bool` (default `false`).

The smaller of the two options in the brief. The ingredients that were not
counted already travel — `ingredients[i].nutrition` uncertainties name each one
and a recipe-level `nutrition` uncertainty summarises them, both added in the
September 2 work and both already rendered by `IngredientList`. Repeating those
names in a list on the nutrition DTO would be a second copy of the same facts
that could disagree with the first, and it would have nowhere to live in the
case that matters most — a recipe where nothing matched has no nutrition block
at all, and its uncertainties still say what happened.

What the boolean adds is the one thing the notes cannot give the client
honestly: a marker it can render without parsing prose. `approximate` is not
`is_estimated`. Every calculated panel is estimated; this one is also
incomplete.

`Contracts/Fixtures/recipe-ready.json` gains `"approximate": false`, and a new
`Contracts/Fixtures/recipe-approximate-nutrition.json` is the decode target for
the client work: totals present, `approximate` true, one ingredient carrying its
"Not counted" note, and the recipe-level summary.

### Persistence (`0024`)

One table, no new column beside the totals.

`nutrition_skips` — one row per skipped ingredient per recipe: recipe FK
(cascade), ingredient name, failure code, estimated grams, recorded timestamp.
Indexed on `recipe_id` and on `ingredient_name`.

**The marker is derived from those rows, not stored.** `to_dtos` batches one
more query — the distinct recipe ids with skips — the same shape as the other
child-table reads it already does, and `_nutrition_dto` takes the answer.
Storing it beside the totals was the first attempt and it is wrong:
`PUT /recipes/{id}` rewrites a recipe's whole graph from the `RecipeDTO` the
client sent, so the first title edit from any already-shipped app — which has
never heard of `approximate` — would write `false` over it while the skip rows
sat there untouched. The rows are the pipeline's own record and no client write
reaches them, so they are the honest source. An integration test pins exactly
that: an older client's edit round-trips and the marker survives.

**Why a table and not a JSON column on `nutrition`.** The recipe where nothing
matched has no `nutrition` row to hang a column off, and that recipe is the most
interesting one the panel will show. And the question the panel asks — which
foods are missed most often, and on whose recipes — is a `GROUP BY` over rows,
which a JSON blob answers only by being unpacked first.

**Where they are written.** `record_nutrition_skips` in
`Backend/ladle/recipes/template_clone.py`, called from all four points that put
a recipe on disk (first clone, private completion, re-import promotion,
re-import candidate) and from `scripts/refresh_recipe_nutrition.py`. It deletes
and re-inserts, so the table always describes what is missing now. It lives
there rather than in the repository graph write because the skips arrive on the
template from a worker that has no recipe id yet, and the recipe id only exists
once the recipe does. They are deliberately not on the wire: the app is served
the names through the uncertainties.

### The panel this feeds (not in this PR)

```sql
SELECT s.ingredient_name, count(*) AS misses, count(DISTINCT s.recipe_id) AS recipes
FROM nutrition_skips s
GROUP BY s.ingredient_name
ORDER BY misses DESC;
```

Join `recipes` on `recipe_id` for the titles each miss came from. `code` says
which rung gave up (`foodNotFound` dominates; `ambiguousFoodMatch`,
`inconsistentNutrients`, `missingMass` are the others), and `estimated_grams`
says how much of a dish the miss was worth.

### The client work this leaves (not in this PR)

- `NutritionView` shows "≈" in front of the calorie figure when
  `recipe.nutrition.approximate`, and lists the skipped ingredients on the sheet
  from the recipe-level `nutrition` uncertainty, which already names them.
- `LadleCore.Nutrition` gains `approximate: Bool` (decode as `false` when
  absent, for recipes synced before this deploy).
- `IngredientList` needs no change: it already renders `ingredient.uncertainty`
  under the row.
- Cards keep no marker — DESIGN.md keeps the estimate marker off cards.
- `LadleTests/NutritionNoteTests.swift` still constructs an
  `insufficientCoverage` blocker as sample text. The server no longer emits that
  code; the test is about rendering an arbitrary blocker and still passes, but it
  is worth rewording when the client work lands.

## Tests

Inverted, because they pinned the behaviour this reverses:

- `test_calculator.py::uncounted_ingredients` — the one-ingredient helper now
  expects `None` rather than an `insufficientCoverage` raise.
- `test_most_of_the_dish_going_uncounted_still_totals_the_rest` (was
  `test_uncounted_mass_over_the_share_blocks_the_recipe`) — 200 g of 500 g
  missing, and the remaining 300 g is still costed.
- `test_one_unmatched_ingredient_leaves_the_others_totalled` (was
  `test_uncounted_mass_at_the_share_is_still_costed`).
- `test_a_stricter_share_blocks_what_the_default_allows` — deleted with the
  setting.
- `test_service.py::test_nothing_matching_names_the_ingredients_without_blocking`
  (was `test_usda_failure_names_the_unavailable_ingredient`) — no blocker, the
  names still on the notes.
- `test_a_heavy_uncounted_ingredient_still_keeps_the_totals` (was
  `test_uncounted_mass_over_the_share_blocks_and_names_the_ingredients`).

New:

- `test_nothing_matched_produces_no_block_rather_than_an_error`.
- `test_the_approximate_marker_survives_a_round_trip_through_a_recipe`
  (`tests/unit/recipes/test_template_clone.py`) — re-import and the refresh
  script both start by re-templating a stored recipe.
- `tests/integration/nutrition/test_nutrition_skips.py` — a partial recipe
  cloned through the real path stores its skip rows and the DTO carries the
  derived marker back out; an older client's edit does not clear it; a second
  run replaces the rows rather than stacking them.
- `tests/integration/test_migrations.py::test_nutrition_skips_upgrade_cascades_and_downgrades`
  — both indexes, the cascade, and a clean downgrade to `0023`.
- `tests/contracts/test_golden_fixtures.py::test_approximate_nutrition_names_what_was_left_out`.

`invalidYield` still blocks the recipe
(`test_unknown_servings_exposes_diagnostic`), unchanged.

## Verification

From `Backend/`, with Docker running:

```
uv run ruff format --check .      344 files already formatted
uv run ruff check .               All checks passed!
uv run mypy --strict ladle        no issues found in 127 source files
uv run pytest                     927 passed
```

`ladle/api/routes/health.py` expects revision `0024`.

## Not done here, deliberately

- No client change. The fixture above is the decode target for it.
- No ops panel and no curated table: both are later PRs, and both were blocked
  on the skips existing, which is what this one adds.
- No second provider. `fallback=None` in production, as before.
