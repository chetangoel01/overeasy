# USDA nutrition: candidate selection, and a local store of the raw records

Date: September 1, 2026

## Purpose

Recipes were importing without any calorie or macro information. The cause was
not the coverage gate an earlier note blamed: normalization succeeded and every
USDA call returned 200, but the calculator discarded the result because of a
single ingredient. In all four failures on the VPS that ingredient was a dried
spice.

Separately, every import re-asked FoodData Central about the same pantry
staples. The responses are now kept locally and consulted first.

## What was wrong

USDA's top hit for `cumin seeds` was `CUMIN SEEDS GRINDER REFILL, CUMIN SEEDS`
(`fdcId 2427784`), a branded record declaring **0 kcal, 0g protein, 0g fat and
133g of carbohydrate per 100g**. The laboratory record `Spices, cumin seed`
(`fdcId 170923`) ranked one place below it and calculates cleanly.

Three defects had to line up:

1. **Ranking put token overlap ahead of data type.** The branded product matched
   both query tokens; `Spices, cumin seed` matched one fewer, only because
   "seeds" is not "seed".
2. **Impossible panels were accepted as candidates.** Nothing rejected a record
   claiming more than 100g of macronutrients per 100g.
3. **Only the top candidate was ever tried.** `_food_required` returned
   `provider_ranked[0]`; one rejection raised and the whole recipe lost its
   nutrition, even though all five candidates had already been fetched.

Observed on the VPS — every nutrition failure, same check, always a spice:

| Recipe | Blocked on |
|--------|-----------|
| Madras Curry | cumin seeds (jeera) |
| Shaved Tofu Wrap | cumin |
| Lasagna Soup | onion powder |
| Single-Serving Shakshuka | garlic powder |

## What changed

- The search asks for the laboratory data types first and only falls back to
  including Branded when nothing generic answers at all. Ranking alone could
  not fix "garlic powder": **every** row USDA returns for it is Branded, so
  there was nothing better to promote. Asking the generic types on their own
  surfaces `Spices, garlic powder`.
- `_search_rank` orders by data type first, then token overlap, then score, so
  laboratory records beat branded label transcriptions within a result set.
- `_plausible` drops records that cannot describe a real food before they
  become candidates: macros summing past 100g per 100g, or zero energy
  alongside real macros.
- `_usable_food` walks the candidate list in rank order and takes the first
  whose nutrients and mass both work. Only when none work does it raise, and it
  reports the leading candidate's failure so the message still names the record
  the ranking believed in.
- The API key moved from `?api_key=` to an `X-Api-Key` header. httpx logs every
  outbound URL at INFO, so the key had been sitting in the worker logs in
  plaintext.
- `usda_foods` and `usda_searches` store the raw responses; the client reads
  them before reaching for the network.
- Indexes added by migrations 0018 and 0019 are now declared on the models.
  They were not, so the schema-drift test had been failing on `main` and
  autogenerate wanted to drop all three.

### All-zero panels, and a correction made during verification

An all-zero panel is kept for a laboratory record and rejected for a branded
one. Water and salt genuinely contribute nothing, so a generic zero is a fact;
a branded zero is a label nobody filled in.

This is not what the first attempt did. It kept every all-zero panel on the
reasoning that ranking would put the laboratory record above the branded one.
Probing the deployed code disproved that: cumin resolved correctly, but garlic
powder still resolved to `fdcId 2104649`, a branded record reporting zero for
everything — so the recipe would have silently totalled that ingredient as
nothing instead of blocking. Ranking cannot help when the whole result set is
branded, which is why the generic-first search exists.

## The local store

`usda_foods` (keyed by `fdc_id`) and `usda_searches` (keyed by the client's own
normalized query) hold **raw payloads**, not parsed columns. That is the point:
ranking and validation run at read time, so a correction like the one above
applies to everything already collected rather than only to what is fetched
afterwards.

Reads and writes use their own short transactions
([store.py](../../Backend/ladle/nutrition/store.py)) and never join the
import's transaction — a cache write has no business extending or failing that
unit of work. Writes upsert, because workers import concurrently and will race
for the same staple.

A stored payload that yields no usable candidate is treated as a miss and
re-fetched, and the fresh response replaces it. This matters more than it
sounds: the first deploy of this work stored branded-only search results, and
without that rule those payloads would have kept answering under the corrected
logic forever — garlic powder would have stayed unresolvable even though the
laboratory record exists. Validating on read is only worth anything if a
payload that fails validation can be replaced.

There is no TTL. FoodData Central records are effectively static; `fetched_at`
is recorded so a refresh policy can be added if that ever stops being true.

USDA becomes the fallback rather than the lookup path: a repeat ingredient
costs no network at all, and a USDA outage or quota exhaustion only affects
ingredients this deployment has never seen.

## Affected components

- `Backend/ladle/nutrition/usda.py` — ranking, plausibility, header auth, store reads
- `Backend/ladle/nutrition/calculator.py` — per-candidate fallback
- `Backend/ladle/nutrition/store.py` — new
- `Backend/ladle/db/models.py` — `USDAFood`, `USDASearch`, and the 0018/0019 indexes
- `Backend/alembic/versions/0020_store_usda_payloads.py` — new
- `Backend/ladle/api/routes/health.py` — expected revision 0019 → 0020
- `Backend/ladle/worker/runtime.py` — wires the store into the calculator

## Verification

- Failing tests first, per the workflow: three calculator tests (fall through
  to the next candidate on impossible nutrients, fall through on unusable mass,
  still block when every candidate fails) and five client tests (generic beats
  a branded name matching more tokens; three impossible panels rejected; the
  key travels in a header). All eight failed before the change.
- Fixtures use the real records measured against the live API: `2427784`,
  `2493482`, `2104649`, `170923`.
- Store round-trip against the testcontainers Postgres: a second client with a
  cold in-process cache serves from the database and makes **zero** HTTP calls;
  repeat saves refresh rather than conflict.
- Deployed-code probe on the VPS for the three ingredients that had been
  failing, which is what exposed the garlic powder gap above.
- Full backend suite: **813 passed**, 2 skipped. Ruff check and format clean.
- The schema-drift and expected-table tests cover migration 0020.

## Fibre: a fourth defect, found by reimporting

After the first three fixes deployed, a reimport still produced nothing — the
block had simply moved from cumin to **cloves**. The cause was the consistency
check itself, not candidate selection.

Atwater charges every gram of carbohydrate 4 kcal. Fibre is largely
unavailable and USDA's stated calories reflect that, so a high-fibre food
looks inconsistent under the naive sum:

| `Spices, cloves, ground` (fdcId 171321, SR Legacy) | |
|---|---|
| USDA stated energy | 274 kcal |
| Naive Atwater on total carbohydrate | 403 → **32% off, rejected** |
| Fibre (33.9 g/100g) treated as unavailable | 267 → 2.4% off |

Consistency is now a band: a panel agrees if its stated energy lies between
"fibre is free" and "fibre is sugar", or within the existing 25% tolerance of
the nearer edge. Where fibre is unreported the band collapses to the naive sum,
which is exactly the previous behaviour, so nothing that passed before can
start failing. Fibre is parsed as an optional nutrient — a record without it,
or reporting it in the wrong unit, keeps working rather than being discarded.

This would have hit every high-fibre ingredient: cloves, cinnamon, cardamom,
chilli powder, cocoa, bran. The recipe that exposed it lists nine spices.

## The query layer

Fixing the blocking exposed the next problem: the pipeline was asking USDA the
wrong questions. `cinnamon stick` returned APPLEBEE'S mozzarella sticks,
`ginger garlic paste` returned almond paste, `fresh coriander` returned
coriander seed at 298 kcal where the recipe means the herb at roughly 23.

Two causes, both fixed here.

**The search terms were culinary, not descriptive.** They are written by the
normalizer, and the whole instruction governing them was one sentence: "Use a
short generic USDA search term". The prompt now states FoodData Central's
convention, gives six worked conversions taken from the failures measured
above, and requires the state that changes the calories — raw, dried, ground,
canned. The usage ledger key moves to `v2` to keep the two prompt generations
apart in accounting; nothing caches a normalization, so no invalidation is
involved.

**The provider-ranked path had no relevance check at all.** It took USDA's
first result on trust; only the fallback path checked that a candidate had
anything to do with the query. Relevance now *orders* candidates rather than
removing them — a candidate qualifies when it carries the query's
distinguishing word — and singular and plural are folded together, which is
the "seeds" against `Spices, cumin seed` problem that started all of this.

Relevance requires the query's **first** word — the one naming the food —
before weighing the rest. Sharing only the qualifiers is how `coriander leaf
raw` matched `Lettuce, leaf, green, raw`: two words of three agreed, and the
one that did not was the only one that mattered. `Carrots, baby, raw` for
`carrot raw` still passes, because the record is free to qualify the food it
names.

A contradicted state is a weak match however well the food matches. `coriander
leaf raw` reaches `Spices, coriander leaf, dried`, where the food and the form
are both right and only the state disagrees — and that disagreement is the
whole difference between 279 kcal per 100g and roughly 23.

**Nothing new blocks.** When no candidate is relevant the recipe is still
costed from the closest row, and a `WeakFoodMatch` is recorded and surfaced as
an `ingredients[n].nutritionMatch` uncertainty. That is deliberate: blocking
would lose every other ingredient's calories over one spice blend USDA has no
entry for, and accepting it silently would present a number nobody should
trust as though it were measured. It also means this change does not depend on
the block-versus-drop question below.

## Refreshing recipes that already exist

Reimporting a recipe creates a second copy and leaves the original behind —
confirmed on the live database, where two "Lasagna Soup" rows share one
`source_video_id`. That makes reimport the wrong tool for "these recipes
should have calories now": seventeen recipes would have become thirty-four,
half of them stale.

`Backend/scripts/refresh_recipe_nutrition.py` re-runs only the nutrition step
against a recipe as it already exists and writes the result onto the same row.
Titles, steps, ingredients, edits and identifiers are untouched, and it only
replaces the uncertainty rows it owns — `nutrition` and
`ingredients[n].nutritionMatch` — so amount estimates and yield rationale from
the original import survive. Dry run by default.

Applied to all seventeen recipes on the Google account on September 1: every
one now carries nutrition, none was duplicated. The six that already had
values moved modestly rather than wildly, which is what better matching should
look like rather than a different calculation.

One property worth knowing: the normalizer re-estimates unquantified amounts
on every run, so two runs of this script over the same recipe differ by a few
percent. These are estimates, and they do not claim otherwise.

## Still open

When *every* candidate for one ingredient is unusable, the recipe still loses
all nutrition. Excluding that ingredient with an uncertainty note and totalling
the rest would be more useful and slightly less accurate. Not decided, so not
changed.
