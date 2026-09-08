# Ladle backend architecture

This describes the implemented backend as of September 8, 2026. The detailed
API contract, provider configuration, and database dictionary live in the
[backend integration reference](../Backend/docs/integration-reference.md).
Local setup and verification commands live in the
[backend README](../Backend/README.md).

## Runtime and responsibilities

| Component | Responsibility |
| --- | --- |
| Python 3.12 / FastAPI | Authentication, import admission and polling, recipe edits, sync, Discover, operator endpoints |
| PostgreSQL 16 / SQLAlchemy / Alembic | Owned recipes, import jobs, shared extraction templates, dispatch intent, quotas, sync sequences, and cleanup records |
| Celery / Redis | Background imports, retries, scheduled recovery and retention; Redis also holds rate limits and operational counters |
| S3-compatible storage / MinIO | Private thumbnails and profile photos served through signed URLs |
| Compose / shared Caddy | Local services and the single-host VPS deployment |

The API and worker share domain services and contracts in `Backend/ladle`.
Blocking API work runs in synchronous routes. iOS remains offline-first with
SwiftData, polls import jobs, and applies the server's recipe change feed.
The Share Extension queues links for the main app to submit. Timers,
notifications, and HealthKit remain on-device.

The VPS uses separate API and worker containers, with Beat embedded in its
worker container, alongside PostgreSQL, Redis, and MinIO. Local Compose uses a
separate Beat service. Deployment settings and the guarded internal TestFlight
exception are documented in the [VPS guide](../Backend/docs/deployment/vps.md).

## Import flow and ownership

1. **Admit.** Validate and canonicalize the social URL, detect duplicates,
   enforce per-user quotas and guest recipe capacity, then commit the job,
   reservation, and dispatch outbox together. Send to Celery after commit;
   maintenance can recover an undelivered outbox record.
2. **Route through the cache.** Shared extraction templates are keyed by source
   ID, source revision, contract version, prompt version, and model ID. A
   versioned claim lets one worker extract while other jobs wait. Cache hits
   clone separately owned recipes; stale public-access checks run before reuse.
3. **Acquire written evidence.** Try free platform metadata, captions, linked
   pages, and published sticker/accessibility text. Video imports may then use
   temporary audio transcription through OpenRouter Whisper, optional Supadata
   and SoScripted, a configured server fallback, and validated creator search.
   Photo posts use their caption and free linked text without buying audio or
   visual extraction.
4. **Gate and extract.** A caption, transcript, or linked page must describe
   cooking. Missing quantities alone do not reject a recipe. Titles and
   sticker/alt text cannot satisfy the gate. The configured extraction model
   produces a validated recipe with uncertainty; images never enter extraction.
5. **Enrich and verify.** Apply explicit creator facts, normalize amounts for
   nutrition, calculate from food records, and run targeted checks. Only
   disputed fields are sent for additional model verification.
6. **Complete.** Persist the recipe graph and sync change, consume its reserved
   slot, and finish the job transactionally. Shared followers receive their own
   copies. Thumbnails are stored for display, with cleanup for abandoned uploads.

`parsing`, `ready`, `needsReview`, `failed`, and `cancelled` are the stored job
states. A sparse video fails with `insufficientTextEvidence`; a photo post with
no cooking method in its caption fails with `photoPostNeedsManualEntry`.

Pasted text and correction notes are encrypted and bypass the public cache.
Pasted text replaces acquisition; correction notes join the available text.
Private re-parses cannot change a shared template. A re-parse replaces the
owned recipe only when its base revision still matches; otherwise it preserves
the cook's edits and holds a candidate for review.

Transient failures preserve the job and its inputs for bounded Celery retries.
An attempt releases its own claim before retrying, including when completion
fails. Independent provider fallbacks still run; an outage that prevents usable
text from being acquired remains retryable. See
[worker reliability](../Backend/docs/import-worker-reliability.md) and
[dispatch recovery](../Backend/docs/import-dispatch-recovery.md).

## Extraction and nutrition

The default extraction adapter is OpenRouter; Anthropic remains an alternative.
The current model defaults live in `Backend/ladle/config.py` and the prompt and
its version in `Backend/ladle/extraction/prompt.py`. The extraction model must
not invent ingredient quantities or nutrition. Serving and cooking-time
estimates carry provenance and uncertainty.

Explicit, complete creator nutrition panels take precedence. Otherwise a
separate normalization stage estimates grams, search terms, and unstated yield
with recorded assumptions. The calculator checks the curated food table before
USDA FoodData Central. USDA responses are stored in PostgreSQL for reuse.

Nutrition degrades per ingredient: unresolvable ingredients are named and
omitted, and partial totals carry `approximate=true`. There is no minimum
coverage floor. If nothing matches, nutrition is absent. Calculated values are
per serving with `servingBasis=1` and `isEstimated=true`. Nutrition failure
alone does not fail the recipe import. See the
[text-only extraction guide](../Backend/docs/text-only-extraction.md) for the
evidence boundary, normalization, provenance, and verification rules.

## Recipe contracts

Python's Pydantic contracts and `Packages/LadleCore` share golden fixtures in
`Contracts/Fixtures`. The wire uses camel-case keys, UUIDs, UTC dates, and
string-encoded decimals. Graph sizes and field lengths are bounded.

An ingredient is a quantity, a unit, and a name. `isToTaste` marks the exception:
an ingredient with no amount to render. `quantityText` preserves the creator's
phrase as an unprinted note. `IngredientDTO.enforce_quantity` recovers a missing
number/unit from that note and marks an unparseable missing amount as
`isToTaste`. Fraction parsing is shared in `ladle/contracts/quantities.py`.

Extraction review and nutrition operate on internal templates before that
public DTO derivation: a missing stated amount is still missing, while a
nutrition estimate is a separate claim about weight. The
`ladle.admin.backfill_ingredient_quantities` command applies the derivation to
older stored recipes. See the
[strict ingredient record](verification/2026-09-08-strict-ingredient-model.md).

Diet, cuisine, and keyword vocabularies live in `ladle/contracts/tags.py`.
The prompt, DTOs, and Discover parameters use those same lists. A vocabulary
change must bump the prompt version. Curated tags are stored in `recipe_tags`;
unreviewed keywords are separate `recipe_keyword_proposals` rows and cannot
enter the filter query.

`diets`, `cuisines`, `keywords`, and `keywordProposals` are tri-state on writes:
missing/null preserves stored values; an empty list clears them. Responses
always contain lists, allowing the app to filter its synced library locally.

## Sync, Discover, and accounts

- **Sync:** `GET /v1/recipes/sync` pages changes by a per-user sequence and
  includes deletion tombstones. Recipe writes carry `baseRevision`; stale edits
  receive `409 syncConflict` with the current recipe. Expired cursors require a
  snapshot reset. This preserves concurrent edits rather than comparing client
  timestamps.
- **Discover:** lists and previews represent shared public sources. Saving a
  preview clones the shared template without a new extraction. Filters run on
  the server before paging: all requested diets and ingredient terms must
  match, while cuisines and keywords each match any requested value. Keyword
  shelves use `/v1/recipes/discover/shelves`; Watch uses the ranked feed without
  a `seen_before` session pin. The integration reference defines paging and
  impression recording.
- **Accounts:** guests use a device installation identity; Apple and Google
  sign-in merge guest data into the account. Sessions use short-lived access
  tokens and rotating refresh tokens. Production validates provider credentials
  and requires App Attest. Profile names and photos travel with refreshed
  account information.

## Operations and verification

Import quotas and atomic provider reservations bound abuse and outstanding
spend. Dollar costs are recorded separately from billed-unit admission limits.
Outbound URL validation pins public DNS targets and checks redirects. Production
startup checks configuration and schema; readiness checks the database, Redis,
worker, and storage. Operator endpoints expose bounded metrics and redacted
request/provider diagnostics.

The [retention policy](../Backend/docs/privacy-retention-and-key-rotation.md)
covers all terminal import states, including cancellation. Avatar uploads
commit cleanup intent before contacting storage and withdraw it only when the
profile save commits. Account deletion and object cleanup have their own durable
records. Backups, restore checks, and rollback remain documented in the
[VPS operations guide](../Backend/docs/deployment/vps.md).

The September 8 recovery changes were verified with failing regressions followed
by passing focused tests and the complete backend suite: **1,107 passed**.
Lint, formatting, and strict typing also passed. These checks use disposable
infrastructure and fake providers; they do not establish the deployed VPS's
health or current live-provider extraction accuracy.

The Debug simulator build of the Ladle app and embedded Share Extension also
succeeded with code signing disabled. No deployment was performed.
