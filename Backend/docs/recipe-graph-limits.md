# Recipe graph limits

## Purpose

Keep recipe mutations, provider output, persistence, sync, and client rendering
within predictable memory, CPU, database, and UI bounds. Validation happens in
the shared `RecipeDTO`, so the same rules apply to manual mutations and imported
recipes before persistence.

## User-visible behavior

An over-limit recipe mutation receives the normal HTTP `422` `invalidRequest`
response. Valid existing fixtures and normal editor/import flows are unchanged.
An imported recipe that violates the contract cannot be written as a partial or
malformed graph.

## Contract limits

| Area | Limit |
| --- | ---: |
| Title / creator | 300 / 200 characters |
| Description / note / instruction | 10,000 / 2,000 / 5,000 characters |
| Ingredient name / preparation | 300 / 500 characters |
| Uncertainty field / reason | 255 / 1,000 characters |
| Images / ingredients / steps | 20 / 200 / 200 |
| Notes / nutrients / top-level uncertainties | 100 / 100 / 200 |
| Timers / ingredient references per step | 20 / 200 |
| Total collection entries | 5,000 |
| Decoded nodes / nesting depth | 10,000 / 8 |
| Servings | greater than zero and at most 10,000 |
| Other decimals | zero or greater and at most 1,000,000 |
| Decimal precision | at most six fractional digits |
| Recipe durations | at most 30 days |
| Source timestamps | at most 24 hours |

Decimals reject NaN and infinity. Step ingredient references must be unique and
must name an ingredient in the same recipe. A source end time cannot precede its
start time. The fixed DTO shape plus the explicit depth and decoded-node budgets
also rejects deeply nested unknown input before ordinary field validation.

## Important decisions

- Limits are deliberately above plausible real recipes (the extraction
  evaluation includes recipes with more than 30 ingredients) but below values
  that can stress database fan-out or client rendering.
- Numeric limits fit the database's `numeric(18,6)` columns with headroom.
- Total complexity is enforced in addition to each list maximum, preventing a
  payload from multiplying individually valid steps and references into a large
  graph.

## Affected components

- `ladle.contracts.recipes`
- Recipe mutation, import/template, cache, and sync paths that use `RecipeDTO`
- `RecipeContractLimits` and the iOS recipe editor validation
- `docs/integration-reference.md`

## Verification

`tests/contracts/test_recipe_limits.py` covers every text/list category,
finite and bounded numbers, durations, reference integrity, aggregate
complexity, decoded-node count, and nesting depth. Golden fixtures plus recipe,
cache, and import integration suites verify existing behavior remains valid.
`RecipeEditorViewModelTests` verifies the app refuses to persist an unsyncable
draft and cannot add more than 200 ingredients or steps.
