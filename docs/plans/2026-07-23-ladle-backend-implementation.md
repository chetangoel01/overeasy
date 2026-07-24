# Ladle Production Backend Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the complete Ladle production backend and connect the native
iOS app to it, including authentication, offline sync, shared per-video
extraction caching, resilient caption/video acquisition, Claude recipe
extraction, estimated nutrition, and safe recovery behavior.

**Architecture:** A modular Python monolith exposes FastAPI endpoints and runs
Celery workers from the same domain/application packages. PostgreSQL owns
identity, jobs, cache claims, recipes, and the monotonic sync feed; Redis is
the Celery broker; S3-compatible storage holds copied thumbnails. Explicit
wire DTOs and shared golden fixtures keep Python and LadleCore compatible.

**Tech Stack:** Python 3.12, uv, FastAPI, Pydantic 2, SQLAlchemy 2, Alembic,
PostgreSQL 16, Celery 5.6, Redis, HTTPX, PyJWT/cryptography, boto3/MinIO,
Claude structured outputs, pytest, testcontainers, Ruff, mypy, Swift 6,
Foundation URLSession, Security/Keychain, SwiftData, XCTest.

---

## Working conventions

- Work only in the `codex/ladle-backend` worktree.
- Follow red-green-refactor for every production behavior.
- Treat each numbered task as one coherent tracked-file change-set for the
  required pre/post Claude Fable consultation in `AGENTS.md`.
- Keep commits task-sized. If a task becomes too large, split it at a green
  checkpoint and repeat the Fable consultation for the new change-set.
- Run `git diff --check` immediately before every commit.
- Never call a live paid provider from the default test suite.
- Never commit `.env`, provider keys, Apple credentials, tokens, transcripts,
  or pasted recipe text.

### Python commands

```bash
cd Backend
uv sync --all-groups
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle
uv run pytest -q
```

Tasks 3 through 8 provision PostgreSQL, Redis, and MinIO exclusively through
testcontainers, so they do not depend on repository Docker Compose files that
do not exist yet. From Task 9 onward, integration and acceptance tests may use
the checked-in Compose stack:

```bash
docker compose up -d postgres redis minio
uv run pytest -m integration -q
```

Live-provider tests are separate and must report skipped rather than silently
passing when credentials are absent:

```bash
uv run pytest -m live_provider -q
```

### Swift commands

```bash
swift test --package-path Packages/LadleCore
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

Use an ignored `.artifacts/DerivedData-*` path for repeated local Xcode runs.

## Task 1: Scaffold the backend toolchain and safe runtime primitives

**Files:**

- Create: `Backend/pyproject.toml`
- Create: `Backend/uv.lock`
- Create: `Backend/README.md`
- Create: `Backend/.env.example`
- Create: `Backend/ladle/__init__.py`
- Create: `Backend/ladle/config.py`
- Create: `Backend/ladle/clock.py`
- Create: `Backend/ladle/observability/__init__.py`
- Create: `Backend/ladle/observability/redaction.py`
- Create: `Backend/ladle/api/app.py`
- Create: `Backend/tests/unit/test_config.py`
- Create: `Backend/tests/unit/test_logging.py`
- Create: `Backend/tests/conftest.py`

**Step 1: Write failing settings and redaction tests**

Test that:

- production startup rejects default signing/encryption secrets;
- settings load provider URLs and timeouts without reading keys into logs;
- `SecretStr` values, bearer tokens, correction notes, and pasted text are
  redacted from structured events;
- an injected `Clock` controls all time-dependent code.

```python
def test_production_rejects_default_secrets() -> None:
    with pytest.raises(ValidationError):
        Settings(environment="production")


def test_sensitive_fields_are_redacted() -> None:
    event = redact_event(
        {"authorization": "Bearer secret", "correction_notes": "private"}
    )
    assert event == {
        "authorization": "[REDACTED]",
        "correction_notes": "[REDACTED]",
    }
```

**Step 2: Verify RED**

Run:

```bash
cd Backend
uv run pytest tests/unit/test_config.py tests/unit/test_logging.py -q
```

Expected: collection fails because `ladle.config` and the redaction module do
not exist.

**Step 3: Add the minimal scaffold**

Configure uv dependency groups and Python 3.12. Add:

```python
class Clock(Protocol):
    def now(self) -> datetime: ...


class SystemClock:
    def now(self) -> datetime:
        return datetime.now(UTC)
```

Use Pydantic settings, explicit secret fields, and a recursive structured-log
redactor. Create a FastAPI app with only metadata; product endpoints come
later. Pin Celery 5.6 and verify that the pin resolves when generating
`uv.lock`.

**Step 4: Verify GREEN and toolchain health**

Run:

```bash
uv run pytest tests/unit/test_config.py tests/unit/test_logging.py -q
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle
```

Expected: focused tests and all three static checks pass.

**Step 5: Commit**

```bash
git add Backend
git commit -m "chore: scaffold Ladle backend runtime"
```

## Task 2: Define explicit transport contracts and shared golden fixtures

**Files:**

- Create: `Backend/ladle/contracts/common.py`
- Create: `Backend/ladle/contracts/imports.py`
- Create: `Backend/ladle/contracts/recipes.py`
- Create: `Backend/ladle/contracts/errors.py`
- Create: `Backend/tests/contracts/test_golden_fixtures.py`
- Create: `Contracts/Fixtures/import-ready.json`
- Create: `Contracts/Fixtures/import-needs-review.json`
- Create: `Contracts/Fixtures/import-failures.json`
- Create: `Contracts/Fixtures/recipe-ready.json`
- Create: `Contracts/Fixtures/recipe-needs-review.json`
- Create: `Contracts/Fixtures/sync-page.json`
- Create: `Contracts/Fixtures/errors.json`
- Create: `Packages/LadleCore/Sources/LadleCore/RemoteContracts.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/RemoteContractTests.swift`

**Step 1: Write failing Python contract tests**

Pin:

- camel-case aliases;
- lowercase UUID strings;
- ISO-8601 UTC fractional dates;
- decimal strings;
- flat import status plus optional failure;
- nullable typed error details;
- exact existing LadleCore enum values.

```python
def test_failed_import_is_flat() -> None:
    value = ImportJobResponse(
        job_id=JOB_ID,
        status=ImportStatus.FAILED,
        failure_reason=ImportFailure.PRIVATE_OR_DELETED,
    )
    assert value.model_dump(mode="json", by_alias=True)["status"] == "failed"
```

**Step 2: Verify Python RED**

Run:

```bash
cd Backend
uv run pytest tests/contracts/test_golden_fixtures.py -q
```

Expected: import failure because contract models do not exist.

**Step 3: Implement minimal Pydantic DTOs and fixtures**

Use an explicit decimal serializer and strict DTOs. Do not serialize SQLAlchemy
models directly.

**Step 4: Verify Python GREEN**

Run the focused contract tests. Expected: every committed fixture is produced
byte-for-byte after normalized key ordering.

**Step 5: Write failing Swift fixture tests**

Add DTOs that decode decimal strings and ISO-8601 dates, then map into
LadleCore:

```swift
@Test func readyRecipeFixtureMapsIntoLadleCore() throws {
    let dto = try fixtureDecoder.decode(
        RemoteRecipeDTO.self,
        from: fixture("recipe-ready")
    )
    let recipe = try dto.recipe()
    #expect(recipe.servings == Decimal(string: "4"))
}
```

Load the repository-root fixtures using a `#filePath`-relative URL. Do not copy
the fixtures into the Swift package. Write the fixture test before the mapper;
the missing mapper's compile failure is the genuine RED.

**Step 6: Verify Swift RED, implement, and verify GREEN**

Run:

```bash
swift test --package-path Packages/LadleCore
```

Expected RED: missing mapper or decoding mismatch. After implementation:
26 existing tests plus the new remote-contract tests pass.

**Step 7: Commit the fixture, serializers, and Swift expectations together**

```bash
git add Backend/ladle/contracts Backend/tests/contracts Contracts Packages/LadleCore
git commit -m "feat: define Ladle remote contracts"
```

## Task 3: Add PostgreSQL models, migrations, and serialized sync allocation

**Files:**

- Create: `Backend/alembic.ini`
- Create: `Backend/alembic/env.py`
- Create: `Backend/alembic/script.py.mako`
- Create: `Backend/alembic/versions/0001_initial_schema.py`
- Create: `Backend/ladle/db/base.py`
- Create: `Backend/ladle/db/session.py`
- Create: `Backend/ladle/db/models.py`
- Create: `Backend/ladle/sync/sequence.py`
- Create: `Backend/tests/integration/test_migrations.py`
- Create: `Backend/tests/integration/test_sync_sequence.py`

**Step 1: Write failing real-Postgres tests**

Use testcontainers, not SQLite. The test suite provisions and tears down its
own PostgreSQL container, so these tasks do not depend on the Docker Compose
stack introduced in Task 9. Cover:

- upgrade from an empty database;
- required unique and foreign-key constraints;
- two database sessions synchronized with barriers around sequence allocation;
- transaction B cannot allocate/commit a later user sequence while
  transaction A holds the user's counter row.

**Step 2: Verify RED**

Run:

```bash
cd Backend
uv run pytest \
  tests/integration/test_migrations.py \
  tests/integration/test_sync_sequence.py \
  -m integration -q
```

Expected: migration/configuration symbols are missing.

**Step 3: Implement the initial schema**

Include every table from the design:

- users, Apple identities, devices, auth sessions;
- recipe slot reservations;
- source videos, claims, cache entries, provider attempts;
- import jobs;
- recipes and child tables;
- user sync state and recipe changes.

Use a partial unique index for unreleased extraction claims and database
constraints for same-recipe step references.

Implement:

```python
def allocate_sequence(session: Session, user_id: UUID) -> int:
    state = session.execute(
        select(UserSyncState)
        .where(UserSyncState.user_id == user_id)
        .with_for_update()
    ).scalar_one()
    sequence = state.next_sequence
    state.next_sequence += 1
    return sequence
```

The transaction owns commit; this helper never commits independently.

**Step 4: Verify GREEN and migration stability**

Run the focused integration tests, then:

```bash
uv run alembic upgrade head
uv run alembic check
```

Expected: tests pass and Alembic reports no new upgrade operations.

**Step 5: Commit**

```bash
git add Backend/alembic.ini Backend/alembic Backend/ladle/db \
  Backend/ladle/sync Backend/tests/integration
git commit -m "feat: add Ladle backend persistence"
```

## Task 4: Implement guest sessions and secure refresh rotation

**Files:**

- Create: `Backend/ladle/auth/tokens.py`
- Create: `Backend/ladle/auth/sessions.py`
- Create: `Backend/ladle/auth/guest.py`
- Create: `Backend/ladle/auth/attestation.py`
- Create: `Backend/ladle/api/routes/auth.py`
- Create: `Backend/tests/unit/auth/test_tokens.py`
- Create: `Backend/tests/integration/auth/test_sessions.py`
- Create: `Backend/tests/api/test_guest_auth.py`

**Step 1: Write failing tests**

Cover:

- random opaque refresh tokens stored only as hashes;
- one-time rotation;
- same-device concurrent refresh inside the injected grace window;
- confirmed reuse revoking the entire family;
- revoked and expired sessions;
- `DELETE /v1/auth/session` revoking the current session and making both its
  access and refresh credentials unusable;
- guest creation rate/attestation hook;
- bearer access-token claims and expiry.

Use barriers with two real Postgres sessions for the concurrent refresh test.

**Step 2: Verify RED**

Run focused unit, integration, and API tests. Expected: auth modules and
endpoints are missing.

**Step 3: Implement minimal secure behavior**

Use constant-time comparisons, SHA-256 token hashes, a signed short-lived JWT
access token, and an opaque refresh secret. Provide a development attestation
adapter and a production interface that fails closed when enforcement is
enabled but no verifier is configured. Implement `DELETE /v1/auth/session` as
the explicit sign-out/revocation endpoint.

**Step 4: Verify GREEN**

Run focused tests plus Ruff and mypy.

**Step 5: Commit**

```bash
git add Backend/ladle/auth Backend/ladle/api/routes/auth.py Backend/tests
git commit -m "feat: add guest authentication sessions"
```

## Task 5: Implement source validation, redirect safety, and stable video IDs

**Files:**

- Create: `Backend/ladle/imports/source_identity.py`
- Create: `Backend/ladle/infrastructure/dns.py`
- Create: `Backend/tests/unit/imports/test_source_identity.py`
- Create: `Backend/tests/unit/imports/test_ssrf.py`

**Step 1: Write failing table-driven tests**

Cover canonical identities for:

- YouTube watch, Shorts, and `youtu.be`;
- TikTok canonical and `vm.tiktok.com`;
- Instagram reel and post URLs.

Cover rejection of:

- non-HTTPS URLs;
- deceptive suffixes such as `youtube.com.example.com`;
- every private/link-local/loopback/multicast IPv4 and IPv6 class;
- IPv4-mapped IPv6;
- redirect loops and more than the allowed hops;
- an allowlisted hostname redirecting to an unapproved host;
- DNS resolve-then-connect rebinding.

Inject both the DNS resolver and transport. Do not use live DNS in unit tests.

**Step 2: Verify RED**

Run:

```bash
cd Backend
uv run pytest tests/unit/imports/test_source_identity.py \
  tests/unit/imports/test_ssrf.py -q
```

Expected: missing source identity module.

**Step 3: Implement minimal validation**

Connect only to the validated resolved address while preserving TLS hostname
verification. Revalidate every redirect hop. Return a typed platform/video ID
or an existing LadleCore-visible failure mapping.

**Step 4: Verify GREEN and commit**

```bash
git add Backend/ladle/imports Backend/ladle/infrastructure/dns.py Backend/tests/unit/imports
git commit -m "feat: validate social video sources"
```

## Task 6: Implement recipe persistence, manual creation, and cursor sync

**Files:**

- Create: `Backend/ladle/recipes/limits.py`
- Create: `Backend/ladle/recipes/repository.py`
- Create: `Backend/ladle/recipes/service.py`
- Create: `Backend/ladle/sync/service.py`
- Create: `Backend/ladle/api/routes/recipes.py`
- Create: `Backend/tests/integration/recipes/test_recipe_service.py`
- Create: `Backend/tests/integration/sync/test_sync_feed.py`
- Create: `Backend/tests/api/test_recipes.py`

**Step 1: Write failing tests**

Cover:

- `baseRevision = 0` idempotently creating a manual recipe;
- `manual.ladle.local` accepted only for an authenticated direct recipe;
- a matching revision update;
- stale revision returning current recipe details;
- soft delete and tombstone;
- pagination with no gaps or duplicates;
- out-of-order transactions serialized by user sync state;
- a guest manual create using the same limit lock as imports.

**Step 2: Verify RED**

Use real Postgres for lock, cursor, and revision behavior.

**Step 3: Implement the minimal repository and API**

Persist full LadleCore structure and allocate a sync change in the mutation
transaction. Return typed `ErrorDTO.details` for conflicts. Put the serialized
per-user recipe-plus-reservation limit check in `recipes/limits.py`; manual
creation uses it here and import admission reuses the same helper in Task 7.

**Step 4: Verify GREEN**

Run focused integration/API tests and contract fixtures.

**Step 5: Commit**

```bash
git add Backend/ladle/recipes Backend/ladle/sync/service.py \
  Backend/ladle/api/routes/recipes.py Backend/tests
git commit -m "feat: persist and sync user recipes"
```

## Task 7: Enforce guest slot reservations and import admission

**Files:**

- Create: `Backend/ladle/imports/reservations.py`
- Create: `Backend/ladle/imports/admission.py`
- Create: `Backend/ladle/api/routes/imports.py`
- Create: `Backend/tests/integration/imports/test_reservations.py`
- Create: `Backend/tests/api/test_import_admission.py`

**Step 1: Write deterministic failing concurrency tests**

Use two Postgres sessions and barriers to prove that:

- parallel new imports at nine saved recipes produce exactly one reservation;
- persisted recipes plus reservations never exceed ten;
- cache followers reserve their own eventual recipe slot;
- retry and re-import do not reserve another slot;
- terminal failure releases;
- success consumes;
- duplicate rejection reserves nothing;
- idempotent submission returns the original job and reservation.

**Step 2: Verify RED**

Expected: naive or missing admission code cannot maintain the invariant.

**Step 3: Implement admission**

Lock the user row, count recipes plus active reservations, insert the job and
reservation atomically, and return typed 409 errors for guest limit and
duplicate. Reuse the per-user limit lock/check from `recipes/limits.py` so
manual creation and imports cannot race each other. Do not enqueue until the
transaction commits.

**Step 4: Verify GREEN and commit**

```bash
git add Backend/ladle/imports Backend/ladle/api/routes/imports.py Backend/tests
git commit -m "feat: admit imports with guest reservations"
```

## Task 8: Implement shared extraction claims, cache cloning, and thumbnails

**Files:**

- Create: `Backend/ladle/cache/claims.py`
- Create: `Backend/ladle/cache/service.py`
- Create: `Backend/ladle/cache/maintenance.py`
- Create: `Backend/ladle/recipes/template_clone.py`
- Create: `Backend/ladle/infrastructure/object_storage.py`
- Create: `Backend/tests/integration/cache/test_claims.py`
- Create: `Backend/tests/integration/cache/test_cache_service.py`
- Create: `Backend/tests/integration/cache/test_thumbnail_storage.py`

**Step 1: Write failing tests**

Cover:

- only one active claim per source video;
- a follower attaches without calling providers;
- lease heartbeat and takeover after injected expiry;
- old leaders cannot complete after losing the lease;
- template cloning assigns fresh recipe/child IDs and strips ownership/edit
  state;
- each attached job consumes its own reservation and emits its own sync
  change;
- bypass jobs never read or write shared cache;
- seven-day public recheck and immediate invalidation;
- private bucket copy, signed URL, reference lifecycle, and cleanup.

Kill the leader between claim and completion in a real-Postgres test; do not
simulate with sleeps.

**Step 2: Verify RED**

Run focused integration tests.

**Step 3: Implement minimal claim/cache/storage services**

Use claim version/owner checks on heartbeat and completion. Store immutable
validated templates. Keep the S3 adapter behind a protocol and use MinIO in
integration tests.

**Step 4: Verify GREEN and commit**

```bash
git add Backend/ladle/cache Backend/ladle/recipes/template_clone.py \
  Backend/ladle/infrastructure/object_storage.py Backend/tests
git commit -m "feat: add shared video extraction cache"
```

## Task 9: Add an executable API-to-worker walking skeleton

**Files:**

- Create: `Backend/ladle/worker/app.py`
- Create: `Backend/ladle/worker/tasks.py`
- Create: `Backend/ladle/acquisition/protocol.py`
- Create: `Backend/ladle/extraction/protocol.py`
- Create: `Backend/ladle/imports/orchestrator.py`
- Create: `Backend/tests/fakes/acquisition.py`
- Create: `Backend/tests/fakes/extraction.py`
- Create: `Backend/tests/e2e/test_fake_import_round_trip.py`
- Create: `Backend/docker-compose.yml`
- Create: `Backend/Dockerfile`

**Step 1: Add the runnable container skeleton**

Create the Dockerfile and Compose services for Postgres, Redis, MinIO, API, and
worker. At this point the containers may start, but the missing task boundary
must still make the end-to-end behavior fail.

**Step 2: Write a failing end-to-end test**

Using Docker Compose and fake production-protocol adapters:

1. create a guest;
2. submit an import;
3. verify a real Celery worker receives it;
4. poll until ready;
5. fetch the created recipe;
6. submit the same video as another user;
7. verify the second request is a cache hit.

**Step 3: Verify RED**

Run:

```bash
cd Backend
docker compose up -d --build postgres redis minio api worker
uv run pytest tests/e2e/test_fake_import_round_trip.py -m integration -q
```

Expected: the API cannot complete the round trip because the
worker/orchestrator behavior is missing.

**Step 4: Implement the minimal real task boundary**

Pass only stable IDs through Celery. The worker loads the job in a transaction.
Set late acknowledgement, visibility timeout, deterministic task IDs, and
idempotent completion.

**Step 5: Verify GREEN and duplicate delivery**

Run the round trip, then publish the same task ID/delivery twice and assert
one recipe/cache completion.

**Step 6: Commit**

```bash
git add Backend
git commit -m "feat: add durable import worker skeleton"
```

## Task 10: Implement provider quotas, circuits, and acquisition adapters

**Files:**

- Create: `Backend/ladle/acquisition/models.py`
- Create: `Backend/ladle/acquisition/coverage.py`
- Create: `Backend/ladle/acquisition/provider_chain.py`
- Create: `Backend/ladle/acquisition/supadata.py`
- Create: `Backend/ladle/acquisition/soscripted.py`
- Create: `Backend/ladle/acquisition/server_fallback.py`
- Create: `Backend/ladle/usage/limits.py`
- Create: `Backend/ladle/usage/circuit.py`
- Create: `Backend/ladle/usage/ledger.py`
- Create: `Backend/docs/provider-contracts.md`
- Create: `Backend/tests/fixtures/providers/supadata/`
- Create: `Backend/tests/fixtures/providers/soscripted/`
- Create: `Backend/tests/unit/acquisition/test_coverage.py`
- Create: `Backend/tests/unit/acquisition/test_provider_chain.py`
- Create: `Backend/tests/unit/acquisition/test_supadata.py`
- Create: `Backend/tests/unit/acquisition/test_soscripted.py`
- Create: `Backend/tests/integration/usage/test_limits.py`
- Create: `Backend/tests/live/test_provider_capabilities.py`

**Step 1: Write failing provider-matrix tests**

Derive recorded/sanitized HTTPX/respx fixtures from the providers' documented
request and response contracts. In `Backend/docs/provider-contracts.md`, record
the official documentation URL, access date, endpoint/API version where
available, and which fixture exercises each capability. Cover:

- sufficient native material;
- Supadata asynchronous transcript and visual jobs;
- visual-only quantities;
- SoScripted transcript fallback;
- private/deleted immediate short-circuit;
- transient retry with injected clock/backoff;
- quota/auth opening a provider circuit;
- empty/malformed output;
- billed-unit ledger entries;
- visual analysis unavailable forcing needs-review coverage.

**Step 2: Verify RED**

Run unit provider tests. Expected: provider modules are missing.

**Step 3: Implement normalized acquisition**

Return `AcquiredVideoContext` with timestamped provenance. Store external job
IDs so worker retries poll rather than resubmit. The optional local adapter
must remain disabled unless explicitly configured.

**Step 4: Verify GREEN and live-smoke reporting**

Run default tests, then:

```bash
uv run pytest tests/live/test_provider_capabilities.py -m live_provider -q
```

Expected without credentials: explicit skips naming missing credentials.
Expected with credentials: one known public video per enabled source reports
provider capabilities without asserting paid calls ran when they did not.

**Step 5: Commit**

```bash
git add Backend/ladle/acquisition Backend/ladle/usage Backend/tests
git commit -m "feat: acquire social video recipe context"
```

## Task 11: Implement Claude extraction, nutrition, and review gating

**Files:**

- Create: `Backend/ladle/extraction/models.py`
- Create: `Backend/ladle/extraction/prompt.py`
- Create: `Backend/ladle/extraction/claude.py`
- Create: `Backend/ladle/extraction/review.py`
- Create: `Backend/tests/unit/extraction/test_prompt.py`
- Create: `Backend/tests/unit/extraction/test_claude.py`
- Create: `Backend/tests/unit/extraction/test_review.py`
- Create: `Backend/tests/live/test_claude_extraction.py`

**Step 1: Write failing tests**

Cover:

- prompt/schema byte-stability snapshot;
- source content delimited as untrusted data;
- ingredient indices mapped to server UUIDs;
- missing servings and nutrition basis defaults with uncertainty;
- model-derived nutrition always estimated;
- confidence below 0.7 and missing quantities over 30 percent;
- refusal, max-token truncation, malformed output, and timeout;
- usable validation problems becoming needs-review rather than hard failure;
- prompt-version change not invalidating an existing shared cache.

**Step 2: Verify RED**

Run focused tests. Expected: extraction modules missing.

**Step 3: Implement minimal structured extraction**

Use the current Anthropic Python SDK helper with Pydantic output, check stop
reason before parsed output, and record token usage without source text.

**Step 4: Verify GREEN and live-smoke reporting**

Default tests use a fake Claude client. The live test is credential-gated and
reports skip state explicitly.

**Step 5: Commit**

```bash
git add Backend/ladle/extraction Backend/tests
git commit -m "feat: extract recipes with uncertainty"
```

## Task 12: Complete import orchestration, retries, reparses, and maintenance

**Files:**

- Modify: `Backend/ladle/imports/orchestrator.py`
- Modify: `Backend/ladle/worker/tasks.py`
- Modify: `Backend/ladle/api/routes/imports.py`
- Create: `Backend/ladle/imports/transitions.py`
- Create: `Backend/ladle/imports/maintenance.py`
- Create: `Backend/ladle/crypto/private_text.py`
- Create: `Backend/ladle/admin/cache_cli.py`
- Create: `Backend/tests/integration/imports/test_orchestrator.py`
- Create: `Backend/tests/integration/imports/test_retry_reparse.py`
- Create: `Backend/tests/integration/imports/test_maintenance.py`
- Create: `Backend/tests/unit/crypto/test_private_text.py`

**Step 1: Write failing lifecycle tests**

Cover:

- every LadleCore-visible import transition;
- provider stage progress and restart from persisted stage;
- retry from failed;
- correction/pasted text encrypted, redacted, and cache-bypassing;
- pasted text skipping acquisition;
- ready re-import replacement only at unchanged base revision;
- failed/needs-review re-import preserving current recipe;
- stale leader takeover;
- expired reservation release only for terminal/stale jobs;
- negative-cache TTL;
- admin cache invalidation CLI;
- no private reparse result entering the shared cache.

**Step 2: Verify RED**

Run focused integration/unit tests.

**Step 3: Implement lifecycle and periodic tasks**

Map all terminal provider detail into the five existing ImportFailure values.
Store richer diagnostic codes only in server DTO fields. Use a KMS protocol;
development uses the configured local key.

**Step 4: Verify GREEN under real Celery**

Run focused tests plus the fake end-to-end round trip with a worker restart
mid-job.

**Step 5: Commit**

```bash
git add Backend/ladle Backend/tests
git commit -m "feat: complete resilient import orchestration"
```

## Task 13: Verify Sign in with Apple and atomically merge guests

**Files:**

- Create: `Backend/ladle/auth/apple.py`
- Create: `Backend/ladle/auth/merge.py`
- Modify: `Backend/ladle/api/routes/auth.py`
- Create: `Backend/tests/unit/auth/test_apple.py`
- Create: `Backend/tests/integration/auth/test_merge.py`
- Create: `Backend/tests/api/test_apple_auth.py`

**Step 1: Write failing tests**

Cover:

- JWKS signature and key rotation;
- issuer, audience, expiry, issued-at, and nonce;
- authorization-code adapter;
- stable subject rather than email;
- first sign-in upgrading a guest;
- existing Apple account plus guest data preserving both;
- deterministic lock order;
- merge idempotency under retry;
- guest token-family revocation in the merge transaction;
- merged recipes emitting destination sync changes;
- source cursors unable to read destination data.

**Step 2: Verify RED**

Run focused auth tests. Expected: Apple and merge services missing.

**Step 3: Implement minimal verification and merge**

Use injected Apple/JWKS transports in default tests. Lock user IDs in sorted
order to avoid deadlocks. Allocate destination sync changes while holding the
destination sync-state lock.

**Step 4: Verify GREEN and commit**

```bash
git add Backend/ladle/auth Backend/ladle/api/routes/auth.py Backend/tests
git commit -m "feat: add Apple sign-in and guest merge"
```

## Task 14: Complete API errors, health, metrics, and deployment gates

**Files:**

- Modify: `Backend/ladle/api/app.py`
- Create: `Backend/ladle/api/dependencies.py`
- Create: `Backend/ladle/api/errors.py`
- Create: `Backend/ladle/api/routes/health.py`
- Create: `Backend/ladle/observability/metrics.py`
- Create: `Backend/ladle/observability/middleware.py`
- Create: `Backend/scripts/check_secrets.sh`
- Create: `Backend/tests/api/test_errors.py`
- Create: `Backend/tests/api/test_health.py`
- Create: `Backend/tests/unit/observability/test_metrics.py`

**Step 1: Write failing tests**

Verify:

- every error uses the contract envelope;
- duplicate and conflict `details`;
- request IDs;
- liveness without dependencies and readiness with DB/Redis/storage;
- metrics for cache/provider/job/sync states without high-cardinality user IDs;
- logs never contain secrets or private text.

**Step 2: Verify RED, implement, verify GREEN**

Add exception mapping, health probes, middleware, and metrics.

**Step 3: Verify deployment**

Run:

```bash
docker compose up -d --build
docker compose ps
curl --fail http://127.0.0.1:4111/health/live
curl --fail http://127.0.0.1:4111/health/ready
uv run alembic check
Backend/scripts/check_secrets.sh
```

Expected: every service is healthy, endpoints return 200, Alembic is stable,
and the secret scan finds no committed secret.

**Step 4: Commit**

```bash
git add Backend
git commit -m "feat: harden Ladle backend operations"
```

## Task 15: Add the iOS HTTP client and Keychain-backed authentication

**Files:**

- Create: `Config/Debug.xcconfig`
- Create: `Config/Release.xcconfig`
- Modify: `project.yml`
- Regenerate: `Ladle.xcodeproj/project.pbxproj`
- Create: `Ladle/Remote/APIClient.swift`
- Create: `Ladle/Remote/APIError.swift`
- Create: `LadleTests/Support/URLProtocolStub.swift`
- Create: `Ladle/Account/AuthClient.swift`
- Create: `Ladle/Account/KeychainTokenStore.swift`
- Modify: `Ladle/Account/AccountSession.swift`
- Create: `LadleTests/APIClientTests.swift`
- Create: `LadleTests/AuthClientTests.swift`

**Step 1: Write failing URLSession and auth tests**

Cover:

- base URL from xcconfig;
- bearer headers and request IDs;
- one refresh and request replay after 401;
- concurrent requests sharing one refresh;
- typed API errors and details;
- Keychain token round trip through an injected store;
- guest bootstrap;
- Apple credential/nonce submission;
- merged account state without losing local recipes.

**Step 2: Verify RED**

Run:

```bash
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:LadleTests/APIClientTests \
  -only-testing:LadleTests/AuthClientTests
```

Expected: client types are missing.

**Step 3: Implement minimal client and auth integration**

Use an actor for token refresh serialization. Keep Keychain access behind a
protocol so tests never touch production Keychain state. No server or provider
secret enters xcconfig.

**Step 4: Regenerate and verify GREEN**

Run `xcodegen generate`, focused tests, all LadleCore tests, and a generic
simulator build.

**Step 5: Commit**

```bash
git add Config project.yml Ladle.xcodeproj Ladle/Remote Ladle/Account LadleTests
git commit -m "feat: connect Ladle account authentication"
```

## Task 16: Replace single-call demo imports with durable remote polling

**Files:**

- Modify: `Ladle/Import/ImportService.swift`
- Create: `Ladle/Import/RemoteImportService.swift`
- Modify: `Ladle/Import/ImportCoordinator.swift`
- Modify: `Ladle/App/AppEnvironment.swift`
- Modify: `Ladle/App/LadleApp.swift`
- Modify: `Ladle/Import/SharedQueueReconciler.swift`
- Modify: `LadleTests/DemoImportServiceTests.swift`
- Modify: `LadleTests/ImportCoordinatorTests.swift`
- Modify: `LadleTests/SharedQueueReconcilerTests.swift`
- Create: `LadleTests/RemoteImportServiceTests.swift`

**Step 1: Write failing protocol and relaunch tests**

Cover:

- submit returning/storing a remote job ID;
- status polling with bounded backoff;
- terminal ready, needs-review, and five failures;
- retry with correction notes/pasted text;
- app relaunch resuming persisted remote jobs;
- cancellation stops polling without cancelling the server job;
- Share Extension envelope submits exactly once;
- duplicate details open the existing recipe;
- `DemoImportService` remains usable only through explicit demo injection.

**Step 2: Verify RED**

Run focused import/reconciler tests. Expected: the old single-call protocol
cannot satisfy polling/resume behavior.

**Step 3: Implement minimal durable service**

Refactor all consumers in one coherent change-set so no commit leaves the
project uncompilable. Preserve current recipe safety during re-import.

**Step 4: Verify GREEN**

Run focused tests, all Ladle app unit tests, LadleCore, and generic app/Share
Extension build.

**Step 5: Commit**

```bash
git add Ladle/Import Ladle/App LadleTests
git commit -m "feat: import recipes through the backend"
```

## Task 17: Add offline-first recipe synchronization

**Files:**

- Create: `Ladle/Sync/RecipeSyncService.swift`
- Create: `Ladle/Sync/SyncCursorStore.swift`
- Create: `Ladle/Remote/RemoteImageCache.swift`
- Modify: `Ladle/Data/StoredRecipe.swift`
- Modify: `Ladle/Data/SwiftDataRecipeRepository.swift`
- Modify: `Ladle/Data/RecipeRepository.swift`
- Modify: `Ladle/App/LadleApp.swift`
- Modify: `Ladle/Library/RecipeGridCard.swift`
- Modify: `Ladle/Library/RecipeListRow.swift`
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Create: `LadleTests/RecipeSyncServiceTests.swift`
- Create: `LadleTests/RemoteImageCacheTests.swift`
- Modify: `LadleTests/SwiftDataRecipeRepositoryTests.swift`
- Modify: `LadleTests/ReimportSafetyTests.swift`

**Step 1: Write failing sync tests**

Cover:

- pushing manual create with base revision zero;
- ordered upserts and tombstones;
- cursor persistence only after successful page application;
- pagination replay idempotency;
- foreground/after-import triggers coalescing into one sync;
- conflict preserving local draft and current server recipe;
- failed/review re-import preserving current recipe;
- post-merge full destination sync.
- downloading signed recipe artwork into a local cache;
- serving cached artwork after the signed URL expires;
- refreshing the recipe DTO and retrying once when an uncached signed URL has
  expired, without an infinite retry loop.

**Step 2: Verify RED**

Run focused app tests. Expected: sync types/repository fields are missing.

**Step 3: Implement minimal actor-based sync**

Store server revision and pending mutation state in SwiftData. Apply each page
transactionally, then advance the cursor. Download remote recipe artwork into
an app-local cache and have shared recipe artwork views prefer the local file.
If an uncached signed URL is expired or rejected, refresh that recipe DTO,
retry the new URL once, and persist the successful local cache reference.

**Step 4: Verify GREEN and commit**

```bash
git add Ladle/Sync Ladle/Data Ladle/App LadleTests
git commit -m "feat: sync Ladle recipes offline first"
```

## Task 18: Run integrated backend and iOS acceptance flows

**Files:**

- Create: `Backend/tests/e2e/test_acceptance_flows.py`
- Create: `docs/verification/2026-07-23-ladle-backend.md`
- Modify as defects require: implementation and test files only

**Step 1: Add failing acceptance coverage**

With fake paid providers but real API, worker, Postgres, Redis, and MinIO,
cover:

1. guest auth and first uncached YouTube import;
2. second user requesting the same video and hitting the shared cache;
3. two concurrent first requests coalescing to one provider/Claude call;
4. Supadata failure falling back to SoScripted;
5. visual-only quantity becoming needs-review when visual provider is down;
6. correction reparse bypassing and not poisoning the cache;
7. failed re-import preserving the usable recipe;
8. guest limit with parallel pending jobs;
9. Apple merge preserving and syncing recipes;
10. manual recipe create/edit/delete and tombstone sync;
11. worker termination and lease takeover;
12. provider/private failure mapping and pasted-text recovery.

**Step 2: Verify RED, fix only genuine integration gaps, verify GREEN**

Run the acceptance file until it passes without modifying the asserted
product contract to accommodate implementation mistakes.

**Step 3: Run the complete fresh verification gate**

Backend:

```bash
cd Backend
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle
uv run pytest -q
uv run pytest -m integration -q
uv run alembic check
scripts/check_secrets.sh
docker compose ps
curl --fail http://127.0.0.1:4111/health/live
curl --fail http://127.0.0.1:4111/health/ready
```

iOS:

```bash
swift test --package-path Packages/LadleCore
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17'
xcodebuild clean build -project Ladle.xcodeproj -scheme Ladle \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .artifacts/DerivedData-backend-final \
  CODE_SIGNING_ALLOWED=NO
test -d \
  .artifacts/DerivedData-backend-final/Build/Products/Debug-iphonesimulator/Ladle.app/PlugIns/LadleShare.appex
git diff --check
```

Live-provider reporting:

```bash
cd Backend
uv run pytest -m live_provider -q
```

Record passed, failed, and credential-skipped checks separately. Never report a
credential-skipped provider as verified live.

**Step 4: Write the verification record**

Document:

- exact commit;
- environment and dependency versions;
- counts for Python, Swift package, app, and UI tests;
- Docker health results;
- acceptance-flow results;
- live-provider pass/skip state;
- any remaining credential or deployment prerequisites;
- only failures actually observed during this branch and any successful
  focused reruns; do not copy baseline simulator boilerplate into the record.

**Step 5: Final Fable review, verify corrections, and commit**

```bash
git add Backend Ladle LadleTests Packages Config project.yml \
  Ladle.xcodeproj Contracts docs
git commit -m "docs: verify Ladle production backend"
```

## Completion handoff

The branch is ready only when Task 18's full gate has fresh passing evidence
or clearly reported credential-skipped live checks. At handoff:

- report the worktree path and branch;
- summarize the shared cache and provider fallback behavior;
- list required environment variables without exposing values;
- identify any live-provider or Apple signing checks that remain blocked by
  credentials;
- offer merge/push/PR options through the finishing-a-development-branch
  workflow.
