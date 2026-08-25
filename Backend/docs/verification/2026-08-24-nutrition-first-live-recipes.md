# Nutrition-First Live Recipe Verification

## Outcome

All five user-supplied social recipes now have complete per-serving calories,
protein, carbohydrate, and fat. Gemini 3.7 Flash interpreted missing weights and
yield; USDA FoodData Central supplied every nutrient value. No video was
reacquired and no recipe was re-extracted.

| Recipe | Yield before → after | Confidence | Per serving: kcal / P / C / F | Whole recipe: kcal / P / C / F |
| --- | --- | ---: | --- | --- |
| French Onion Pasta | 4 estimated → 4 estimated | 0.80 | 1080.3 / 31.5 g / 73.5 g / 71.8 g | 4321.2 / 126.0 g / 294.0 g / 287.2 g |
| Chili Garlic Noodles | 2 stated → 2 stated | 0.95 | 835.8 / 27.5 g / 75.9 g / 46.6 g | 1671.6 / 55.0 g / 151.8 g / 93.2 g |
| Chicken & Gnocchi | 2 stated → 2 stated | 1.00 | 1348.1 / 70.1 g / 89.7 g / 74.3 g | 2696.2 / 140.2 g / 179.4 g / 148.6 g |
| Hoisin Garlic Noodles | 1 estimated → 4 estimated | 0.90 | 563.4 / 17.6 g / 88.1 g / 16.2 g | 2253.6 / 70.4 g / 352.4 g / 64.8 g |
| Cucumber Ribbon Salad | 1 estimated → 4 estimated | 0.80 | 175.9 / 4.1 g / 23.5 g / 7.1 g | 703.6 / 16.4 g / 94.0 g / 28.4 g |

These are estimates, not laboratory measurements. The rich pasta and gnocchi
totals are high because their preserved recipes contain large amounts of cream,
cheese, pancetta, chicken, and/or gnocchi divided into only two to four servings.

## Material assumptions

- French Onion Pasta uses the 9 oz midpoint of an 8–10 oz pasta range; deglazing
  water is excluded.
- Chili Garlic Noodles uses 80 g dry noodles per stated portion; to-taste salt is
  excluded.
- Chicken & Gnocchi treats the deglazing option as 30 g white table wine and
  excludes to-taste seasoning and optional garnish.
- Hoisin Garlic Noodles estimates one tablespoon of vegetable oil, selects maple
  syrup, and corrects the implausible one-serving yield to four.
- Cucumber Salad selects mirin rather than water and corrects four cucumbers from
  one serving to four.

## Diagnostics that improved the pipeline

- Original to-taste ingredients may be explicitly normalized or excluded. The
  coverage guard still requires every material ingredient.
- The calculator preserves FoodData Central's unique search relevance order;
  unranked sources retain strict ambiguity rejection.
- Stale USDA search rows whose detail endpoint returns 404 are skipped.
- Wine and vinegar may contain valid non-macro energy, so authoritative USDA
  calories are accepted for those categories while the general inconsistency
  guard remains active.

## Spend and timing

The five saved normalizations represented `$0.04069725` of the successful
pipeline cost. The first diagnostic pass plus the one explicitly bounded retry
spent `$0.06578925` total. Including the earlier five-link feasibility probes,
nutrition normalization exploration cost approximately `$0.1030`.

The saved normalization/first-USDA attempts took 2.0–11.1 seconds per recipe.
The final sequential USDA-only replay completed in roughly 77 seconds and made
no model calls. The standalone report includes the successful pipeline cost,
not discarded diagnostic attempts.

## Artifact

`tools/pipeline-results.html` embeds the five enriched recipes and renders
per-serving calories/macros, derived whole-recipe calories, USDA FDC evidence,
serving confidence, yield rationale, and assumptions. No credential or signed
media URL is embedded.
