# Ladle Production Backend Design

## Status

Approved for implementation on `codex/ladle-backend`.

This design replaces the rough backend guideline with one cohesive production
architecture. The backend, provider pipeline, shared video cache,
authentication, sync, and iOS integration are designed together. Implementation
may be dependency-ordered, but no disposable phase-specific service or contract
will be introduced.

## Product intent

The backend replaces `DemoImportService` and local-only account state with:

- reliable recipe imports from public YouTube, TikTok, and Instagram videos;
- shared reuse of a successful extraction for subsequent requests of the same
  video;
- native-caption, post-text, transcription, and visual-analysis fallbacks;
- field-level uncertainty and visibly estimated nutrition;
- guest identity, Sign in with Apple, and lossless guest-to-account merge;
- durable recipe storage and offline-first synchronization;
- safe re-import, correction-note parsing, and pasted-text recovery.

The iOS app remains the cooking and editing experience. Timers,
notifications, HealthKit, and the primary SwiftData store remain on-device.

## Explicit non-goals

- Social feeds, follows, comments, or recipe discovery
- Server-side timers, notifications, or HealthKit writes
- Search infrastructure beyond a user's local library
- Proxying requests through a user's social-media credentials or cookies
- Supporting private, login-required, paywalled, or age-restricted videos
- Treating estimated nutrition as medically authoritative
- Splitting the backend into independently deployed microservices

## Architecture

Ladle uses a modular monolith: one Python codebase with two process types and
clear internal module boundaries.

```text
iOS app
   |
   v
FastAPI API -----------------------------+
   |                                     |
   | transactions and enqueue            | polling and sync
   v                                     |
Postgres <---- Celery worker <---- Redis broker
   |                 |
   |                 +--> transcript/video providers
   |                 +--> Claude structured extraction
   |                 +--> S3-compatible image storage
   |
   +--> auth, imports, recipes, cache, sync, usage ledger
```

The API and worker share the same domain and application packages. Celery is
used instead of `arq` because `arq` is in maintenance-only mode, while the
pipeline needs actively maintained retry, acknowledgement, worker isolation,
and monitoring behavior for long-running external calls.

### Source organization

```text
Backend/
  ladle/
    api/             FastAPI routes, dependencies, error mapping
    auth/            guests, Apple identity, sessions, merge
    contracts/       explicit Pydantic request and response DTOs
    imports/         job lifecycle, orchestration, retry rules
    acquisition/     source identity, captions, transcripts, video analysis
    extraction/      Claude schema, prompt, review gate, nutrition
    cache/           shared source-video extraction templates and claims
    recipes/         ownership, edits, copies, deletion
    sync/            monotonic change feed and conflict handling
    infrastructure/  Postgres, Redis, Celery, HTTP, object storage adapters
    observability/   structured logging, metrics, usage ledger
  alembic/
  tests/
  Dockerfile
  docker-compose.yml
  pyproject.toml
```

Domain code does not import FastAPI, Celery, SQLAlchemy, or a provider SDK.
Application services depend on protocols; infrastructure modules implement
those protocols. The API and worker are composition roots.

## Technology choices

| Layer | Choice |
| --- | --- |
| Runtime | Python 3.12 |
| API | FastAPI and Pydantic 2 |
| Persistence | PostgreSQL 16, SQLAlchemy 2, Alembic |
| Queue | Celery 5.6 with Redis |
| Object storage | S3-compatible API; MinIO locally |
| Caption and transcript providers | Supadata, then SoScripted |
| Structured extraction | Claude Opus 4.8 structured outputs |
| Optional server fallback | `yt-dlp`, `ffmpeg`, `faster-whisper`, disabled by default |
| Tests | pytest, pytest-asyncio, HTTPX, testcontainers |
| Local orchestration | Docker Compose |

All dependencies are pinned through a lockfile. Provider SDKs are optional
implementation details; adapters may use plain HTTP when that yields a smaller
and more stable surface.

## Transport contract

`LadleCore` remains the domain source of truth, but the HTTP contract uses
explicit DTOs rather than Swift's synthesized `Codable` representation.
Associated Swift enums such as `.failed(ImportFailure)` must not leak their
compiler-generated nested JSON shape onto the wire.

### Encoding rules

- JSON keys use the existing LadleCore lower-camel-case names.
- UUIDs are lowercase hyphenated strings.
- Dates are ISO-8601 UTC with fractional seconds.
- Decimal values are JSON strings and are converted explicitly to and from
  Swift `Decimal`.
- Enum values use the existing LadleCore raw values.
- Import state uses `{ "status": "failed", "failureReason":
  "privateOrDeleted" }`, with a client DTO mapping into `ImportStatus`.
- Unknown recipe platforms map to `RecipeSource.other`.
- Provider-specific errors never appear as new `ImportFailure` values.
- The server may return a typed diagnostic code in the error envelope while
  still mapping the visible job failure into one of LadleCore's five cases.

### Required-field behavior

The extractor may not provide values that LadleCore requires:

- `originalURL` is always the validated canonical request URL. A manual recipe
  uses the client's existing `https://manual.ladle.local/<uuid>` convention.
- Missing `servings` defaults to `1` and creates a low-confidence uncertainty.
- `Nutrition` is omitted when a meaningful estimate cannot be produced.
- When `Nutrition` exists, `servingBasis` defaults to `1` with an uncertainty
  if the source does not identify a basis.
- The extraction model emits ingredient indices, not UUIDs. The server assigns
  UUIDs and resolves step-to-ingredient references after validation.

### Contract verification

Backend serializers produce committed golden JSON fixtures for:

- every import status and visible failure;
- a complete ready recipe;
- a needs-review recipe with missing quantities;
- estimated nutrition with absent optional nutrients;
- sync upserts and tombstones;
- duplicate and conflict errors.

Swift tests decode these fixtures through the remote DTO layer and map them
into LadleCore. Python tests load the same fixtures through Pydantic. Contract
drift fails both test suites.

## Data model

### Identity and sessions

```text
users
  id, kind(guest|apple), created_at, merged_into_user_id

apple_identities
  apple_sub(unique), user_id, created_at

devices
  id, user_id, installation_id, attestation_state, created_at, last_seen_at

auth_sessions
  id, user_id, device_id, token_family_id, refresh_token_hash,
  previous_refresh_token_hash, previous_valid_until, expires_at,
  revoked_at, created_at, rotated_at

recipe_slot_reservations
  id, user_id, import_job_id, state(reserved|consumed|released),
  created_at, expires_at
```

Refresh tokens are opaque random secrets stored only as hashes. Rotation is
one-time-use, detects replay, and revokes the token family on confirmed reuse.
A short grace window permits the same installation's concurrent refresh
requests without falsely treating them as theft.

### Shared source identity and extraction cache

```text
source_videos
  id, platform, platform_video_id, canonical_url, public_access_confirmed_at,
  source_revision, metadata_json, created_at, checked_at
  unique(platform, platform_video_id)

extraction_claims
  id, source_video_id, owner_job_id, lease_expires_at, heartbeat_at,
  unique active claim per source_video_id

extraction_cache
  id, source_video_id, source_revision, contract_version, prompt_version,
  model_id, template_json, review_status, created_at, invalidated_at

provider_attempts
  id, import_job_id, provider, operation, external_job_id, status,
  latency_ms, billed_units, failure_code, created_at, completed_at
```

`template_json` is an immutable, validated base recipe without user IDs,
recipe IDs, favorites, edits, correction notes, pasted text, or user
timestamps. It may reference a shared copied thumbnail in object storage.

A successful cache entry is reused indefinitely by default. A lightweight
source metadata check may establish a new source revision when the platform
reports that public source content changed. Model or prompt changes alone do
not silently invalidate a successful cache. Explicit user reparse and
administrative invalidation are supported.

Before serving a positive cache entry whose public-access check is older than
seven days, the worker performs a lightweight public-access check. This does
not rerun captions, transcription, visual analysis, or Claude. A later
`privateOrDeleted` observation immediately invalidates the positive entry.

Private/deleted results may be negative-cached for a short TTL to avoid
repeated provider spending, but private or unlisted content is never placed in
the shared positive cache.

### User imports and recipes

```text
import_jobs
  id(client generated), user_id, source_video_id, source_url, canonical_url,
  source, status, stage, failure_reason, diagnostic_code, retry_count,
  bypass_cache, correction_notes_encrypted, pasted_text_encrypted,
  current_recipe_id, candidate_recipe_id, cache_entry_id,
  idempotency_key, created_at, updated_at, completed_at

recipes
  id, user_id, source_video_id, source_cache_id, title, description,
  creator_name, source, original_url, preparation_minutes, cooking_minutes,
  total_minutes, servings, favorite, review_status, deleted_at,
  revision, created_at, updated_at

recipe_images
ingredients
recipe_steps
step_ingredients
detected_timers
nutrition
other_nutrients
field_uncertainties
```

Recipe child tables preserve LadleCore IDs and order indices. Referential
constraints ensure step ingredient references belong to the same recipe.
Pydantic validation runs before persistence.

Correction notes and pasted text are encrypted at rest, excluded from logs,
retained only as long as needed for recovery, and never copied into the
shared cache.

For guests, a new import reserves one recipe slot at admission under the same
per-user lock used for recipe creation. Persisted recipes plus active
reservations may never exceed ten. Each import that will create a recipe,
including a coalesced follower, owns one reservation. A successful completion
atomically consumes it; a terminal failure releases it. Re-imports and retries
of an existing recipe do not reserve another slot. Expired abandoned
reservations are released by an idempotent maintenance task only after their
jobs are terminal or irrecoverably stale.

### Sync changelog

```text
recipe_changes
  user_id, sequence, recipe_id, kind(upsert|delete), recipe_revision,
  changed_at
  primary key(user_id, sequence)

user_sync_state
  user_id(primary key), next_sequence
```

Each user has a monotonically increasing server-side sequence allocated in
the same transaction as a recipe mutation. Allocation locks the user's
`user_sync_state` row with `FOR UPDATE` and holds that lock through commit, so
sequence order and commit order cannot diverge. A sync cursor is the last
applied sequence, not a timestamp. Deletes create durable tombstones.
Changelog compaction is deferred; v1 retains the complete change history.

## Import submission and cache behavior

### Stable source identity

Only allowlisted public YouTube, TikTok, and Instagram hosts are accepted.
Short links are resolved with:

- HTTPS only;
- a strict redirect limit;
- DNS and resolved-address checks blocking loopback, link-local, private,
  multicast, and cloud-metadata ranges;
- an allowlisted destination host on every redirect.

The canonical identity is `(platform, platform_video_id)`, not the raw URL.
Tracking parameters and presentation variants therefore share one cache key.

### Cache hit

1. Authenticate, validate the source, enforce quota, and create or retrieve
   the idempotent import job.
2. Resolve the stable source identity.
3. If an active public cache entry exists and `bypassCache` is false, clone
   the template into a new user-owned recipe in one transaction.
4. Consume the guest slot reserved at admission.
5. Mark the job ready or needs-review and emit a sync change.

No caption, transcript, video-analysis, Claude, or nutrition provider is
called on a cache hit.

Importing another copy for the same user still uses the shared cache, but
creates a distinct recipe. Without `allowDuplicate`, the API returns a typed
duplicate response containing the existing recipe ID.

### Cache miss and concurrent requests

An import job attempts to acquire a database extraction claim. The claim has
a renewable lease and a unique active constraint per source video.

- The leader performs acquisition and extraction.
- Followers attach to the claim and remain visible as parsing.
- A leader heartbeat renews the lease.
- If the leader crashes, a follower can take over after lease expiry.
- Every provider attempt has a deterministic idempotency key.
- Every stage is safe under Celery's at-least-once delivery.
- Persisting the shared cache entry and completing attached jobs is
  transactional and idempotent.

This prevents duplicate billing without leaving waiters stuck after a worker
crash.

### Cache bypass

Correction notes, pasted recipe text, and explicit reparsing set
`bypassCache = true`.

- The result is owned by the requesting user.
- It never reads from or writes to the shared positive cache.
- It never mutates the existing shared template.
- A failed re-import preserves the current usable recipe.
- A needs-review candidate does not replace a current usable recipe.
- A ready candidate replaces the current recipe only if its base recipe
  revision has not changed since re-import began. Otherwise the job becomes
  needs-review so an automated result cannot overwrite newer user edits.

## Caption, transcript, and visual acquisition

Many videos display burned-in text rather than exposing machine-readable
subtitle tracks. Recipe quantities may appear only onscreen. The pipeline
therefore evaluates both spoken and visual content.

### Provider-neutral result

All provider adapters normalize into:

```text
AcquiredVideoContext
  canonical source identity
  public metadata and post description
  timestamped native/generated transcript segments
  visual text and structured observations with timestamps
  language
  provenance for every field
  provider confidence and diagnostics
```

Provider output and source text are treated as untrusted data, never as
instructions. They are delimited from system prompts and size-limited.

### Acquisition order

1. Retrieve public metadata, post description, and any native caption track.
2. Run a deterministic coverage check for recipe-like ingredients,
   quantities, and ordered instructions.
3. When native material is absent or incomplete, call Supadata's transcript
   and video-analysis APIs to recover spoken and visual content.
4. On a Supadata timeout, transient error, empty result, quota outage, or open
   circuit, call SoScripted as an independent transcription fallback.
5. If explicitly enabled, use the server-side
   `yt-dlp`/`ffmpeg`/`faster-whisper` adapter as an emergency fallback.
6. If no usable context remains, return the recoverable parser failure and
   retain the source URL for pasted-text or manual recovery.

`privateOrDeleted` short-circuits the chain. It must not spend credits across
every provider. Transient errors retry with bounded exponential backoff and
jitter. Provider authentication or quota failures open a circuit breaker.
The Celery visibility timeout exceeds the worst supported processing time,
and tasks use late acknowledgement only where idempotency is proven.

SoScripted is a transcription fallback, not a replacement for Supadata's
visual analysis. If Supadata visual analysis is unavailable and transcript or
post text still lacks quantities or instructions, the result is explicitly
needs-review with field uncertainties. When the optional server adapter is
enabled, it may sample frames for OCR as a visual fallback. Provider
capability smoke tests verify the supported-source matrix before production
enablement.

Raw downloaded media is deleted immediately after processing. Provider
payloads and transcripts use short retention and are not exposed between
users.

## Structured recipe extraction

Claude receives labeled source metadata, transcript segments, visual
observations, post text, and any private correction context. It produces a
Pydantic extraction schema, not the public Recipe DTO directly.

The extraction schema:

- uses ingredient indices instead of UUIDs;
- carries confidence and an optional uncertainty reason for every relevant
  field;
- permits absent quantities and optional nutrients;
- instructs the model never to invent a quantity;
- includes per-serving estimated nutrition in the same request;
- never sets `isEstimated` false for model-derived nutrition.

After the response:

1. Check stop reason before reading structured output.
2. Treat refusal, truncation, timeout, and provider errors explicitly.
3. Validate all values and cross-references server-side.
4. Assign UUIDs and resolve ingredient indices.
5. Convert validation problems into uncertainties where a usable recipe
   remains.
6. Mark needs-review when any confidence is below `0.7`, required defaults
   were used, or more than 30 percent of ingredients lack quantities.
7. Fail with `parserUnavailable` only when no safe, usable recipe exists.

The system prompt and schema are versioned and byte-stable for prompt caching.
Usage, latency, model ID, stop reason, and billed tokens are recorded without
logging source text or credentials.

## Authentication and account merge

### Guest

`POST /v1/auth/guest` registers an installation and returns:

- a short-lived signed access token;
- a rotating opaque refresh token;
- the server user ID.

Production guest creation requires App Attest or DeviceCheck validation when
configured. Per-installation, per-user, per-IP, and global cost limits remain
mandatory even with attestation.

The server enforces the ten-recipe guest limit through transactional slot
reservations. Each import that can create a recipe consumes one slot,
including a coalesced follower; retries and re-imports of existing recipes do
not. Terminal failures release their reservation.

### Sign in with Apple

The iOS client supplies the Apple identity token, authorization code, and
nonce proof. The server validates:

- the JWKS signature and key ID;
- issuer;
- audience equal to the configured bundle ID;
- expiration and issued-at bounds;
- nonce;
- the authorization code with Apple where required.

The stable Apple subject, not email, identifies the account.

### Atomic merge

Signing in while authenticated as a guest performs the merge in the same
endpoint and transaction:

1. Lock the guest and destination users.
2. Reassign or reconcile guest recipes and import jobs.
3. Preserve both sides when the Apple account already contains data.
4. Emit destination-user sync changes for every merged recipe.
5. Revoke guest token families.
6. Mark the guest merged.
7. Return destination-user tokens.

The operation accepts an idempotency key, so a network retry cannot merge
twice or lose data.

## Recipe sync and conflict policy

`GET /v1/recipes/sync?cursor=<sequence>&limit=<n>` returns ordered upserts and
tombstones plus `nextCursor` and `hasMore`. Serialized per-user sequence
allocation and a consistent transaction snapshot ensure pages do not skip
changes.

Client mutations include `baseRevision`.

- `baseRevision = 0` creates a client-originated recipe with a client-generated
  UUID and is idempotent. For guests, this create path consumes a slot under
  the same reservation/limit lock as imports.
- Direct user-created recipes may use `RecipeSource.other` and the existing
  `https://manual.ladle.local/<uuid>` URL convention. That host is accepted
  only for authenticated recipe creation/sync, never as an import or outbound
  fetch target.
- A matching revision is accepted, increments the recipe revision, and emits
  a sync change.
- A stale revision returns `409 syncConflict` with the current server recipe.
- The iOS client preserves its draft and lets the user retry against the
  current version; it does not silently discard either version.
- Automated re-import never overwrites a recipe edited after the re-import
  began.

SwiftData remains the immediate local source for views. The client pushes
pending edits and pulls sync changes on foreground, after authentication,
after an import completes, and after retryable connectivity returns.

## HTTP API

All endpoints use `/v1`, bearer access tokens, JSON, request IDs, and explicit
idempotency keys for mutating operations.

```text
POST   /v1/auth/guest
POST   /v1/auth/apple
POST   /v1/auth/refresh
DELETE /v1/auth/session

POST   /v1/imports
GET    /v1/imports/{jobID}
POST   /v1/imports/{jobID}/retry

GET    /v1/recipes/sync
GET    /v1/recipes/{recipeID}
PUT    /v1/recipes/{recipeID}
DELETE /v1/recipes/{recipeID}

GET    /health/live
GET    /health/ready
```

`POST /v1/imports` accepts a client-generated job ID, source URL,
`allowDuplicate`, and an optional idempotency key. Correction notes and pasted
text are accepted only on retry/reparse paths and always bypass the shared
cache.

### Error envelope

```json
{
  "error": {
    "code": "guestRecipeLimitReached",
    "message": "Create a free account to save more recipes.",
    "retryable": false,
    "requestID": "...",
    "details": null
  }
}
```

Expected codes include invalid URL, unsupported source, duplicate recipe,
guest limit, authentication required, sync conflict, provider unavailable,
quota exceeded, and rate limited. HTTP 409 is used for duplicate, guest-limit,
and sync-conflict domain states; 402 is not used.

`details` is a code-specific object:

- duplicate errors include `existingRecipeID`;
- sync conflicts include the current recipe DTO and revision;
- rate limits include a retry timestamp;
- all other errors use `null` unless their contract explicitly defines a
  payload.

## iOS integration

The current `ImportService.importRecipe(for:)` models one delayed local call,
not a durable submit-and-poll service. It will evolve to explicit operations:

```text
submit(job) -> remote job identifier and status
status(remote job identifier) -> parsing / terminal outcome
retry(remote job identifier, correction notes, pasted text) -> status
```

`ImportCoordinator` persists the remote identifier, polls with bounded
backoff, and resumes pending jobs after app relaunch. The Share Extension
continues to enqueue a small App Group record; the main app reconciles it into
a remote submission.

Additional client services:

- `AuthClient` manages guest registration, Apple sign-in, token refresh, and
  Keychain persistence.
- `RecipeSyncService` pushes pending mutations and applies ordered changes and
  tombstones to SwiftData.
- Remote DTOs own transport decoding and map into LadleCore.
- `DemoImportService` remains available only for previews and deterministic UI
  tests, never as the production default.

Debug configuration reads the API base URL from xcconfig. No secret or
provider key is embedded in the app.

## Security and privacy

- Allowlisted social hosts and SSRF-safe redirect resolution
- Strict request, transcript, video-duration, and response-size limits
- Hashed rotating refresh tokens with family replay detection
- Apple nonce and full JWS claim validation
- App Attest/DeviceCheck hook plus rate and cost limits
- Encryption at rest for pasted text and correction notes
- A production KMS-managed encryption key, with a local-only development key
  supplied through environment configuration
- No provider keys, bearer tokens, transcripts, or private text in logs
- Public-access confirmation before a result can enter the shared cache
- No user social-media credentials or cookies
- Constant-time token comparisons
- CORS disabled except for explicitly configured development origins
- Dependency and container vulnerability scanning
- Provider egress allowlisting in production

## Quotas and cost control

- Guest recipe limit: ten saved recipes
- Per-user daily and monthly import limits
- Per-IP and per-installation guest creation/import limits
- Maximum supported video duration and source-text size
- Global daily provider and Claude spend ceilings
- Provider billed units and Claude token usage recorded per job
- Cache hits recorded separately and do not consume provider quota
- Circuit breakers prevent retry storms during provider outages

## Observability and operations

Structured logs include request ID, job ID, stage, provider, attempt number,
latency, and terminal state. They exclude source text and credentials.

Metrics include:

- imports by status and source;
- cache hit, miss, coalesced-follower, and bypass rates;
- provider success, latency, fallback, circuit, and billed-unit counts;
- Claude usage, refusal, truncation, and validation rates;
- queue age, retry count, and lease takeover count;
- sync conflicts and merge results;
- guest-limit and quota rejections.

Local development uses:

```text
api.ladle.localhost -> 127.0.0.1:4111
Postgres
Redis
MinIO
FastAPI API
Celery worker
```

Docker health checks gate readiness. Alembic migrations run as a separate
one-shot command, never concurrently in every API worker.

## Testing strategy

Development follows red-green-refactor.

### Python unit tests

- URL validation, canonical video identity, and SSRF defenses
- transport encoding for dates, decimals, enums, and failures
- cache hit, miss, bypass, invalidation, and negative-cache behavior
- recipe template cloning without shared ownership or edits
- review-gate and uncertainty propagation
- provider result normalization and failure mapping
- refresh rotation, grace, replay detection, and revocation
- Apple claim and nonce validation
- guest-limit enforcement and merge reconciliation
- sync conflict decisions and cursor serialization

### Concurrency tests

- two imports for the same video call providers once;
- a follower takes over after a leader lease expires;
- duplicate Celery delivery is idempotent;
- parallel guest saves at nine never exceed ten;
- concurrent refreshes use the grace path without hiding replay;
- an idempotent guest merge is safe under retry;
- re-import cannot overwrite a concurrently edited recipe.

### Provider-matrix tests

Provider fakes cover:

- native material sufficient;
- Supadata transcript fallback;
- Supadata visual analysis for onscreen-only quantities;
- SoScripted fallback after a transient Supadata failure;
- private/deleted short-circuit;
- provider quota/auth circuit opening;
- empty or malformed provider responses;
- all providers failing into pasted-text recovery.

Default tests never call paid or live providers. Optional credential-gated
smoke tests run against one known public fixture per supported source.

### Persistence and integration tests

- Alembic upgrade from an empty PostgreSQL database
- transactional cache completion and attached-job fan-out
- out-of-order transaction commits remain visible in the sync feed
- pagination never skips or duplicates a change
- tombstone delivery and replay
- post-merge changes appear to the destination user
- private-bucket thumbnail copy, signed serving URLs, shared-reference
  lifecycle, and cleanup behavior
- API authentication, ownership, idempotency, and typed errors

### Swift tests

- golden backend fixtures decode and map into LadleCore;
- `RemoteImportService` submission, polling, retry, cancellation, and relaunch;
- Keychain auth refresh and guest-to-Apple transition;
- ordered sync upserts, tombstones, and conflict preservation;
- Share Extension queue reconciliation submits exactly once;
- current recipe remains safe during failed or conflicting re-import.

### Completion gate

The integrated backend is complete only when:

- Python formatting, linting, type checking, unit, integration, migration, and
  contract tests pass;
- LadleCore and relevant app tests pass;
- the full iOS app and Share Extension build succeeds;
- Docker Compose health checks pass;
- local end-to-end cache miss, cache hit, retry-bypass, auth merge, and sync
  flows pass using provider fakes;
- credential-gated live-provider smoke results are reported separately rather
  than simulated;
- no required production secret is committed.

## External credentials and deployment boundary

The repository will contain complete adapters and configuration for Supadata,
SoScripted, Claude, Apple, object storage, and App Attest/DeviceCheck, but it
will not invent credentials. Automated tests use fakes. Live smoke tests and
production deployment become available when the corresponding environment
variables and Apple configuration are supplied.
