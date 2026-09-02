# Nutrition degrades per ingredient, with a floor on how much may be missing

Date: September 2, 2026

Follows [the September 1 USDA work](2026-09-01-usda-nutrition-fix-and-store.md),
which fixed *which* record an ingredient resolves to. This changes what happens
when no record resolves at all.

## Purpose

A recipe lost every calorie because one ingredient could not be costed. Twelve
ingredients would resolve cleanly, `garam masala` would not, and the panel
showed nothing — which is the wrong trade in both directions: the cook loses
eleven-twelfths of a usable estimate, and the one ingredient that failed is
never named.

From issue #37: an unresolvable ingredient is now skipped and reported, and the
rest of the dish is totalled. A floor on estimated **mass** decides when too
much has been skipped for the remaining number to mean anything.

## Decisions in force

All three are the repository owner's, recorded in issue #37 and unchanged here.

1. **Degrade per ingredient.** Four failures belong to one ingredient —
   `foodNotFound`, `ambiguousFoodMatch`, `inconsistentNutrients`, `missingMass`
   — and are recorded and stepped over. `invalidYield` and
   `noMaterialIngredients` stay whole-recipe: neither leaves anything to total.
2. **The floor is on mass, not on a count of ingredients.** Skipping curry
   leaves is nothing; skipping the chicken is the dish.
3. **A weak match is treated as unmatched.** Costing a vegetarian curry from
   `Beef curry` is not an imprecise number but a wrong one, and the flag beside
   it never undid that. Before an ingredient could be dropped, costing it badly
   was the only alternative to showing nothing; that trade is gone, and
   `WeakFoodMatch` goes with it.

## What changed

### Calculator

`calculate_required` catches the four per-ingredient codes inside the material
loop, appends an `UncountedIngredient(index, name, code, estimated_grams)` to a
new `uncounted` out-parameter, and continues. The out-parameter is filled
*before* a coverage block is raised, so the blocked path can name the
ingredients too.

`_usable_food` still orders relevant candidates ahead of irrelevant ones, and
now rejects an irrelevant one when it reaches it. Because the ordering runs
first, reaching an irrelevant candidate means every relevant candidate was
already unusable — so this is a gate, not a re-ranking, and the ingredient is
left uncounted rather than costed from a record nothing believes in.

**The floor.** `_grams` needs a food's portion table for volume units, which an
unmatched ingredient has not got, so the floor weighs `estimated_grams`: the
normalizer's own figure, written in grams for every ingredient it keeps. A
recipe is blocked with a new whole-recipe code `insufficientCoverage` when

    uncounted_grams / (counted_grams + uncounted_grams) > share

or when nothing at all was counted — otherwise a recipe whose every ingredient
failed would present zero calories as a finding. `share` is
`Settings.nutrition_uncounted_mass_share_limit`, default `0.25`, and is in
`.env.example`. The comparison is strict, so exactly a quarter is costed.

**The provider seam.** `NutritionCalculator(source, fallback=None, *,
uncounted_mass_share_limit=…)`. The fallback is asked only about ingredients the
primary source could not answer, so the common case still costs one search per
ingredient, and its candidate goes through the same consistency, mass and
relevance checks. `FoodDataSource` gains a `name`, and the evidence line names
the source per food — `USDA FDC 23, Fake Foods 9001` — so a panel drawn from two
providers stays checkable. Production passes `fallback=None` until the provider
for PR B is chosen; `tests/fakes/nutrition.py` stands in for it in tests and
answers the four known USDA gaps.

### Service

`insufficientCoverage` blocks through `_blocked`, and the blocker names the
ingredients that could not be counted. Otherwise each uncounted ingredient
becomes a `FieldUncertaintyDTO(field="ingredients[{i}].nutrition")` reading
*"Not counted: no nutrition record found for X."*, and one recipe-level
`nutrition` uncertainty summarises *"1 of 8 ingredients not counted: tomato."*

`enrich` grows the same `uncounted` out-parameter, so the tuning script reads
the skipped ingredients directly instead of parsing a blocker string.

**Two corrections the brief did not anticipate.**

*The brief expected `RecipeTemplateCloner` to distribute `ingredients[i].*`
uncertainties onto rows. It does not — and nothing else does either.*
`instantiate` copies `TemplateIngredient.uncertainty` to `IngredientDTO`
one-to-one and the recipe-level list to `RecipeDTO.uncertainties`; no code on
either side of the wire reads a field path and routes it. So the existing
`nutritionMatch` note never reached the row it named. The service now writes the
note into `TemplateIngredient.uncertainty` directly, which is the same thing
`normalization.py` does for `nutritionAmount`. That slot holds one note, shared
with extraction's own doubt about the row: **the newer note wins**, because
someone reading a total that leaves an ingredient out needs that before a
confidence score.

*Stale notes had to be cleared.* Re-enrichment reads a stored recipe back
through `RecipeTemplate.from_recipe`, last run's notes included. `_cleared`
removes everything this module authors — `nutrition`, `ingredients[i].nutrition`
and the retired `ingredients[i].nutritionMatch` — from both the recipe list and
the ingredient rows before the new notes are written. The normalizer's
`nutritionAmount` is deliberately left alone: it belongs to the amount estimate,
not the lookup.

`field == "nutrition"` no longer means "blocked" on its own — a costed recipe
carries the summary on that field. Every reader now checks whether nutrition is
present first.

### Refresh script

`scripts/refresh_recipe_nutrition.py` prints counted against uncounted grams and
the resulting share beside each calorie change, and names every skipped
ingredient with the code that skipped it. That column is what tunes the default.
It also now writes an `ingredients[i].*` note against that ingredient's row
(`FieldUncertainty.ingredient_id`), which is what puts it under the ingredient
in the app rather than nowhere.

### Client

`NutritionNote.uncounted(in:)` reads the recipe-level `nutrition` uncertainty,
and only when the recipe has nutrition to show — a blocked recipe's `nutrition`
field carries an engineer-facing blocker and there is no panel to put it on.
`NutritionView.servingNote` renders it under "Per serving".

`IngredientList` needed no change: it already renders `ingredient.uncertainty`
under the row, which is where the per-ingredient note now lands.

The card's `libraryFacts` is untouched — DESIGN.md keeps the estimate marker off
cards.

## The dry run that set the floor

Read-only `pg_dump --data-only` of the live library through `docker exec` on the
VPS's `ladle-postgres-1`, loaded into a **scratch** database
(`ladle_nutrition_scratch`) on the local Compose Postgres, and the dry run
executed there against this branch. **No new code ran on the production host and
nothing was applied anywhere.** `usda_searches` and `usda_foods` came across with
the rest, so most lookups were served from the store; the 43 search terms not
already cached were fetched live from USDA, and normalization re-ran through
OpenRouter, so masses differ slightly from the stored ones.

All 28 live recipes, across all seven users:

| # | Recipe | Calories | Counted | Uncounted | Share | Not counted |
|---|--------|----------|--------:|----------:|------:|-------------|
| 1 | Spicy Tofu & Chicken Noodles | 611 → 618 | 1331 g | 10 g | 0.01 | Rice vinegar |
| 2 | High-Fiber Cilantro Lime Rice | 296 → 285 | 540 g | 0 g | 0.00 | |
| 3 | Fiber-Rich Cilantro Lime Rice | 293 → 290 | 325 g | 0 g | 0.00 | |
| 4 | Creamy Italian Sausage Rigatoni | 625 → 675 | 4253 g | 0 g | 0.00 | |
| 5 | Fiber-Rich Cilantro Lime Rice | 286 → 281 | 316 g | 0 g | 0.00 | |
| 6 | **Paneer Bhurji** | 1094 → 1051 | 560 g | 123 g | **0.18** | tomato |
| 7 | Gobi Manchurian | 104 → 252 | 628 g | 0 g | 0.00 | |
| 8 | Egg Bhurji | 582 → 336 | 533 g | 15 g | 0.03 | ghee, garam masala |
| 9 | Scalloped Potatoes | 473 → 486 | 2087 g | 0 g | 0.00 | |
| 10 | Single-Serving Shakshuka | 524 → 525 | 375 g | 0 g | 0.00 | |
| 11 | 10-Minute Chili Garlic Noodles | 888 → 909 | 599 g | 0 g | 0.00 | |
| 12 | Single-Serving Shakshuka | 496 → 521 | 372 g | 0 g | 0.00 | |
| 13 | Lasagna Soup | 565 → 567 | 2940 g | 0 g | 0.00 | |
| 14 | The Best Vegan Pizza! | 912 → 876 | 1716 g | 1 g | 0.00 | Italian herb mix |
| 15 | Shaved Tofu Wrap | 586 → 560 | 877 g | 0 g | 0.00 | |
| 16 | Madras Curry | 722 → 751 | 961 g | 1 g | 0.00 | green cardamoms |
| 17 | Lasagna Soup | 626 → 566 | 2939 g | 0 g | 0.00 | |
| 18 | Stuffed bell peppers | none → 505 | 350 g | 0 g | 0.00 | |
| 19 | Stuffed bell peppers | none → 456 | 340 g | 0 g | 0.00 | |
| 20 | Unknown Recipe | none → none | 0 g | 0 g | — | *blocked: noMaterialIngredients* |
| 21 | Stuffed Bell Peppers | none → 558 | 1451 g | 0 g | 0.00 | |
| 22 | Madras Curry | none → 409 | 993 g | 5 g | 0.01 | curry leaves |
| 23 | Single-Serving Shakshuka | none → 439 | 350 g | 12 g | 0.03 | lentils |
| 24 | Stuffed bell peppers | none → 456 | 340 g | 0 g | 0.00 | |
| 25 | Stuffed Bell Peppers | none → 538 | 1453 g | 0 g | 0.00 | |
| 26 | Creamy Italian Sausage Rigatoni | 625 → 677 | 4169 g | 4 g | 0.00 | Italian seasoning |
| 27 | **One Pot Creamy French Onion Pasta** | 1075 → 745 | 1902 g | 227 g | **0.11** | pancetta |
| 28 | 10-Minute Chili Garlic Noodles | 840 → 906 | 596 g | 0 g | 0.00 | |

Every uncounted ingredient failed as `foodNotFound`.

### What the table says

**Nothing in the library is blocked by the floor at 0.25.** The worst recipe
sits at 0.18. Nine recipes that carry no nutrition today gain it; none lose it.
The single block is `noMaterialIngredients` on a recipe with no ingredients,
which is a pre-existing whole-recipe failure and not a coverage decision.

**0.25 keeps its default, and the margin is thinner than it looks.** The two
recipes that come closest are the ones where a *main* ingredient failed — 123 g
of tomato in a 683 g dish, 227 g of pancetta in 2129 g — which is exactly what
the floor is for. Anything below about 0.15 would start blocking recipes that
are only missing a spice-sized share of a small dish; anything much above 0.3
would let half a chicken go missing silently. The library has no example
between 0.18 and 1.0, so the number is set by judgment about what the floor is
*for* rather than by a cluster in the data — worth revisiting once the second
provider shrinks the uncounted set.

**The uncounted set is wider than the four known gaps.** `tomato`, `ghee`,
`pancetta`, `lentils`, `Italian seasoning`, `Rice vinegar` and `green
cardamoms` are not composite regional blends; they are ordinary ingredients the
relevance gate now refuses rather than costing badly. That was the predicted
consequence of treating weak matches as unmatched, and it raises the value of
PR B's provider: seven distinct terms, none exotic, would likely be answered by
a natural-language food API.

## Affected components

- `Backend/ladle/nutrition/calculator.py` — `UncountedIngredient`, the coverage
  floor, the fallback rung, per-source evidence
- `Backend/ladle/nutrition/service.py` — row notes, the recipe-level summary,
  clearing last run's notes
- `Backend/ladle/nutrition/usda.py` — `FoodDataSource.name`
- `Backend/ladle/config.py`, `Backend/.env.example` —
  `nutrition_uncounted_mass_share_limit`
- `Backend/ladle/worker/runtime.py` — passes `fallback=None` and the share
- `Backend/scripts/refresh_recipe_nutrition.py` — the coverage column,
  ingredient-scoped uncertainty rows
- `Backend/tests/fakes/nutrition.py` — new, the deterministic second provider
- `Ladle/Nutrition/NutritionNote.swift` — new
- `Ladle/Nutrition/NutritionView.swift`, `Ladle/RecipeDetail/RecipeDetailView.swift`
- `LadleTests/NutritionNoteTests.swift` — new

No migration, and no wire change: the note travels on `FieldUncertaintyDTO`,
which the contract already carries, so `Backend/docs/integration-reference.md`
is unchanged.

## Verification

- Failing tests first. Five calculator tests and one service test were inverted
  rather than deleted — they pin the behaviour this reverses — and eleven new
  ones added: one unmatched of many totals the rest; over-the-share blocks with
  `insufficientCoverage`; exactly the share is still costed; a stricter share
  blocks what the default allows; the fallback is consulted once and costed; a
  weak match reaches the fallback before being dropped; a fallback that also
  fails leaves the ingredient uncounted; an unusable yield is still whole-recipe.
- Backend: `uv run pytest` — **839 passed**. `ruff format --check`, `ruff check`
  and `mypy --strict ladle` all clean.
- iOS: `xcodebuild test … -only-testing:LadleTests` — **408 executed, 1 skipped,
  0 failures**. `NutritionNoteTests` was verified red by removing the
  "only when there is a panel" guard.
- The dry run above, over the real library, applied to nothing.

## Captures

Overeast UI validation simulator (`614AF85D-84AF-4371-BF70-5D5DA2BBA683`),
launched `-ui-testing -onboarding-complete`, status bar frozen at 9:41 and
cleared afterwards. The demo library's Garlic Butter Udon carries an uncounted
`oyster sauce` so both notes have somewhere to appear.

- `captures/2026-09-02-nutrition-fallback/recipe-detail-not-counted.png` — the
  row note under the ingredient, with the totals still shown above it.
- `captures/2026-09-02-nutrition-fallback/nutrition-panel-summary.png` — the
  recipe-level summary under "Per serving".

## Left for later

- **The second provider is PR B.** It needs a key and a provider choice
  (Nutritionix or Edamam); Open Food Facts stays ruled out. The seam is in
  place and unused.
- **The floor is defaulted, not fitted.** The library contains no recipe between
  0.18 and total failure, so `0.25` is a judgment. Re-run this dry run after PR
  B lands and the shape of the uncounted set will have changed.
- **A refresh does not rewrite ingredient rows themselves.** `--apply` replaces
  nutrition and uncertainty rows, including the ingredient-scoped ones, but it
  does not touch the ingredient records; nothing in this change needs it to.
- The per-ingredient note is written twice — once against the ingredient row and
  once in the recipe-level list. Only the first is rendered; the second is what
  `_cleared` and the refresh script's owned-field sweep work from. Harmless, and
  cheaper than a second channel.
