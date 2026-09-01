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

- `_search_rank` orders by data type first, then token overlap, then score, so
  Foundation and SR Legacy records beat branded label transcriptions.
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

### One deliberate non-change

An **all-zero panel is still accepted**. Water and salt genuinely contribute
nothing, and rejecting their records would block any recipe listing water. The
branded all-zero spice records that used to slip through — a garlic powder
record reporting zero for everything passes the consistency check while
silently contributing nothing — are handled by ranking instead, which now puts
the laboratory record above them.

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
- Full backend suite: **811 passed**, 2 skipped. Ruff check and format clean.
- The schema-drift and expected-table tests cover migration 0020.

## Still open

When *every* candidate for one ingredient is unusable, the recipe still loses
all nutrition. Excluding that ingredient with an uncertainty note and totalling
the rest would be more useful and slightly less accurate. Not decided, so not
changed.
