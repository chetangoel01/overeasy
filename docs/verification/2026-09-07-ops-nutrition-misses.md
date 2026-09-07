# The ingredients nutrition did not count, on the operator dashboard

Date: September 7, 2026

Stacked on [the no-coverage-floor PR](2026-09-07-nutrition-no-coverage-floor.md)
(#104), which is Tier 0 of issue #37 and the thing that made `nutrition_skips`
exist. This is the **panel** half of the "Decisions, 2026-09-07" comment:

> Every skipped ingredient is recorded server-side and surfaced as a panel on
> the ops dashboard (`/ops`, PR #93): unmatched names by frequency, with the
> recipe each came from. That panel is the backlog for the table.

The curated table itself is a sibling PR, seeded from the same names.

## Purpose

The skip rows have two readers with opposite needs. The cook is told about
their own recipe, in prose, on the ingredient row — "Not counted: no nutrition
record found for garam masala." The operator needs the other cut: the same food
across the whole corpus, ranked, so the next row of the curated table is
obvious rather than guessed.

Ordering the panel by frequency is what makes it a work queue. The four gaps
found by hand in September — `garam masala`, `curry leaves`,
`ginger garlic paste`, `tamarind` — are the seed; this panel is how the fifth
is found without anybody going looking.

## User-visible behaviour

A **Nutrition** section on `/ops`, above **System**, with one card, **Not
counted**. It is all-time; the dashboard has no window selector and this is a
standing backlog rather than a rate, so it gains none.

Each row is one ingredient name:

| column | what it says |
| --- | --- |
| Ingredient | the name, exactly as recorded, with a bar for its share of the worst offender |
| Recipes | how many distinct live recipes carry the miss |
| Misses | how many skip rows, all time |
| Est. mass | the summed `estimated_grams`, or `–` where none was estimated |

Under the name: the failure codes in plain words (`foodNotFound` → "no record",
`ambiguousFoodMatch` → "no relevant record", `inconsistentNutrients` → "record
contradicted itself", `missingMass` → "no mass to cost") with a count each, the
raw code in the tooltip. Under that: up to three recipe titles, then "+ N more".

The sub-heading says "Showing the top 25 of 41 names", so truncation is visible
rather than something the operator has to know about.

### Decisions worth naming

**The names are not prettified.** Not trimmed, not title-cased, not
deduplicated by any normalisation. The string on the panel is the string the
calculator handed the lookup, and the curated table has to answer *that*
string. It is set with `textContent` inside a `white-space: pre-wrap`
monospace span rather than interpolated into markup, because HTML collapses
the leading space that is exactly the sort of thing worth noticing, and the
tooltip shows the JSON-quoted literal for copying.

**Recipes are named, not linked.** The dashboard has no recipe view and every
recipe belongs to a cook, so there is nothing to link to. The title is the
readable handle and the id is in the tooltip.

**Deleted recipes do not vote.** API deletion is soft. Every query joins
`recipes` and filters `deleted_at IS NULL`; without it the head of the backlog
could be work for recipes nobody has any more. Exercised by a test that deletes
a recipe through `RecipeService` and expects its two names to disappear from
both the list and the totals.

**Sixty seconds, not five.** This is the only dashboard read that reaches
Postgres. It sits on the readiness poll's timer, is excluded from the request
log (`observability/middleware.py`) and from the dashboard's own traffic
charts (`OPS_ROUTES`), the same way the other three polls are.

## The endpoint

`GET /ops/nutrition-misses.json`, in `Backend/ladle/api/routes/ops.py`, with
the same `OpsAccessPolicy.authorize` as `metrics.json`, `requests.json` and
`readiness.json`: a client certificate the gateway verified, or the dashboard
cookie, and a 404 — not a 401 — for anything else, so the dashboard stays
invisible to a public scan.

`policy.authorize(request)` is the first statement in the handler and the
session is opened after it, deliberately *not* through `Depends(database)`:
FastAPI resolves dependencies before the handler body, so a `Depends` would
hand every unauthenticated scanner a database session before refusing it.
`tests/api/test_ops_dashboard.py` pins the 404, and it passes with no database
configured at all — which is the proof that no query ran.

```json
{
  "generatedAt": "2026-09-07T12:00:00+00:00",
  "limits": { "names": 25, "examples": 3 },
  "totals": { "names": 41, "skips": 137, "recipes": 61 },
  "names": [
    {
      "name": "garam masala",
      "skips": 12,
      "recipes": 9,
      "estimatedGrams": 41.5,
      "codes": [
        { "code": "foodNotFound", "skips": 10 },
        { "code": "ambiguousFoodMatch", "skips": 2 }
      ],
      "examples": [
        { "id": "…", "title": "Chicken Curry" },
        { "id": "…", "title": "Dal Tadka" }
      ]
    }
  ]
}
```

`estimatedGrams` is `null` where every row for a name recorded no mass.
`totals` counts the whole live table, so the browser can say how much of it it
is not showing. `examples` is bounded, and `recipes - examples.length` is the
"+ N more" beside them.

## The read model

`Backend/ladle/nutrition/misses.py`. Four queries, all joined to `recipes` and
filtered on `deleted_at IS NULL`:

1. totals — distinct names, rows, distinct recipes.
2. the top `NAME_LIMIT` (25) names, ordered `count(*) DESC, ingredient_name`.
   The name breaks the tie so a reload does not reshuffle the middle of the
   list under the operator, and so the tests can assert an order.
3. the code breakdown for those names only, `count(*) DESC, code`.
4. the recipes for those names, ranked in the database by a `row_number()`
   window partitioned on the name and cut at `EXAMPLE_LIMIT` (3).

**On the bound, honestly.** Ranking names by frequency reads every live skip
row — that is what a `GROUP BY` is, and no index removes it. What is bounded is
everything downstream: queries 3 and 4 touch only the 25 names query 2 chose,
the reply is at most 25 names × 3 recipes however large the library gets, and
the browser lays out a fixed number of rows. A materialised summary is the next
step if the aggregate ever costs anything; at the current corpus size it does
not, and pre-aggregating now would be inventing a cache for a table with three
figures in it.

The window's `ORDER BY` is `recorded_at DESC, title, id`, not `recorded_at`
alone: `recorded_at` defaults to `now()`, which in Postgres is transaction
start, so every skip written in one transaction shares a timestamp and the
sample would otherwise be whatever the planner felt like.

## Affected components

- `Backend/ladle/nutrition/misses.py` — new; the read model and its two bounds.
- `Backend/ladle/api/routes/ops.py` — the endpoint and its JSON shape.
- `Backend/ladle/api/routes/ops_dashboard.html` — the panel, its styles, its
  poll, and the new route in `OPS_ROUTES` and `ROUTE_NOTES`.
- `Backend/ladle/observability/middleware.py` — the new poll joins `_POLLED`,
  so a successful one is not logged and a failing one still is.

No migration, no contract change, no client change: this reads rows `0024`
already created and nothing here crosses the app's wire.

## Tests

- `tests/integration/nutrition/test_nutrition_misses_panel.py` — six recipes
  through `RecipeService`, one of them deleted. Pins the frequency order, the
  distinct-recipe and row counts, the summed mass, the two-code breakdown with
  its tie-break, the three-of-five truncation with its ordering, the totals,
  the verbatim name with its leading and trailing spaces, `null` mass, and an
  empty table answering 200 rather than an error.
- `tests/api/test_ops_dashboard.py` — the 404 for an unauthenticated caller,
  beside the three neighbouring ops endpoints; and the page carrying the
  panel's mount point and the URL it polls.
- `tests/unit/observability/test_middleware.py` — the new poll is not logged
  when it succeeds.

The panel's rendering was checked outside the browser by extracting the inline
script and running `renderMisses` against a stub DOM with a seeded payload:
the name arrives as text with its whitespace intact, a recipe title containing
`<` is not interpreted as markup, "+ 7 more" follows the two shown recipes, a
`null` mass renders `–`, and the empty state renders its sentence. That harness
is a one-off and is not checked in — there is no JS test runner in this repo.

## Verification

From `Backend/`, with Docker running:

```
uv run pytest tests/integration/nutrition -n0    9 passed
uv run pytest                                    931 passed
uv run ruff format --check .                     346 files already formatted
uv run ruff check .                              All checks passed!
uv run mypy --strict ladle                       no issues in 128 source files
```

Not exercised: the panel against the live host. It needs the dashboard's mTLS
material, which is out of scope here, and it would be empty anyway — see below.

## What the panel will not show yet

The backfill the #104 doc describes has not run. Recipes enriched before
`nutrition_skips` existed carry their "N of M ingredients not counted" notes
and no rows, so they are invisible here until
`scripts/refresh_recipe_nutrition.py --apply` runs on the host. The panel's
empty state says so rather than claiming a clean library. Until then the
ranking is over recipes imported since the deploy only, which is a smaller and
more recent sample than it looks.

## Noticed, deliberately not fixed here

`OPS_ROUTES` in the dashboard script has never contained `/ops/requests.json`,
so the recent-requests poll is counted in the traffic charts even though the
footer says the dashboard's own polling is always excluded. Adding it changes
existing traffic numbers, which is not this change's business; it is a one-line
fix worth its own commit.
