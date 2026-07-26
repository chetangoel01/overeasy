# Ladle production backend verification — 2026-07-24

## Frontend-to-backend live re-verification, 2026-07-26

### Purpose and user-visible behavior

The production iPhone composition was rechecked against the completed local
backend. A user can finish guest onboarding, paste either a TikTok or Instagram
recipe link, see the import reach `ready` or `needsReview`, open the returned
recipe, and return to the library. The same remote service is used for imports
reconciled from the Share Extension when the main app becomes active.

The app continues to keep import work durable locally before submission. It
polls the backend by job ID, saves terminal recipes through the offline-first
repository, synchronizes server revisions, and preserves parsing or failed
jobs in the import inbox.

### Affected components and decisions

- `LadleApp` keeps production builds on `AuthClient`, `APIClient`,
  `RemoteImportService`, and `RecipeSyncService`; deterministic UI tests still
  use `DemoImportService`.
- `LadleUITests/ImportFlowTests.swift` now contains a live TikTok and Instagram
  round trip that accepts both valid terminal outcomes and fails on the
  recovery screen.
- `LadleLiveBackend.xcscheme` selects that live test. The normal `Ladle` scheme
  explicitly skips it so the regular suite remains deterministic and does not
  consume provider quota.
- The test handles duplicate recipes by requesting another copy, then verifies
  navigation into the real recipe detail screen.
- The test-only library preference reset clears grid/list and collapsed or
  dismissed section choices so deterministic UI launches always expose the
  Import Inbox.
- The live scheme starts with a fresh installation identity, authentication
  session, sync cursor, and local library. The Add Recipe action remains
  disabled until guest bootstrap completes, closing the launch-time race
  between a visible library and the first authenticated request.

### Evidence

On an iPhone 17 simulator running the Debug app against
`http://api.ladle.localhost`:

| Source | Backend job created | Terminal state | Recipe opened |
| --- | --- | --- | --- |
| TikTok `7655788084671401247` | `2026-07-26 05:11:21 UTC` | `ready` | Yes |
| Instagram `Cx8pqZDv7G0` | `2026-07-26 05:11:30 UTC` | `ready` | Yes |

The fresh app launch also created a real backend guest user, device, and auth
session at `2026-07-26 05:11:13 UTC`. The two UI-created import rows had no new
`provider_attempts` because both videos were shared-cache hits. This run proves
the iPhone authentication, HTTP submission, polling, terminal recipe fetch,
local persistence, and navigation path. It intentionally does not claim a new
provider acquisition or extraction call.

### Verification

```bash
curl --fail http://api.ladle.localhost/health/live
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme LadleLiveBackend \
  -destination 'platform=iOS Simulator,id=1CE0C07F-8CDD-41E5-9B38-DD908B5F5CBD'
```

Result: one selected live UI test passed in 24.024 seconds, covering both
sources. The app and embedded Share Extension Debug build also passed.

The remainder of this document records the original backend milestone at
commit `6a8bdd8`; later acquisition, Whisper, frame-analysis, and OpenRouter
work supersedes its provider-boundary notes.

## Scope

This record verifies the production Ladle backend and the native iOS
integration described by
`docs/plans/2026-07-23-ladle-backend-implementation.md`.

Verified product areas:

- guest authentication, Sign in with Apple, token rotation, and atomic
  guest-to-account merge
- durable URL and pasted-text imports with retry, crash recovery, usage
  reservations, and typed failures
- shared canonical-video extraction caching across users
- concurrent cache-claim coalescing so one video incurs one extraction
- caption and transcript acquisition through Supadata, then SoScripted, plus
  a disabled server media/ASR adapter seam awaiting a concrete processor
- Claude structured recipe extraction, estimated nutrition, per-field
  uncertainty, and review gating
- private/corrected re-parses that bypass and cannot poison the public cache
- safe cached and uncached re-imports that preserve the current recipe until a
  replacement is usable
- offline-first recipe create/edit/delete, ordered delta sync, tombstones,
  conflict preservation, and signed artwork caching
- guest limits, duplicate handling, observability, redaction, readiness, and
  deployment configuration

## Verified tree and environment

- Implementation commit: `6a8bdd8`
- Branch: `codex/ladle-backend`
- Worktree:
  `/Users/chetangoel/Desktop/Repositories/recipe-app/.worktrees/ladle-backend`
- macOS 26.5.2
- Xcode 26.5 (build 17F42)
- iPhone 17 Pro simulator, iOS 26.5
- Python 3.12.13 through uv 0.11.28
- FastAPI 0.139.2, SQLAlchemy 2.0.51, Celery 5.6.3, Pydantic 2.13.4
- Docker 29.4.0

## Automated verification

| Check | Result |
| --- | --- |
| `uv run ruff format --check .` | 134 files formatted |
| `uv run ruff check .` | Pass |
| `uv run mypy ladle` | 82 source files, no issues |
| `uv run pytest -q` | 136 passed, 3 credential-skipped |
| `uv run pytest -m integration -q` | 41 passed |
| Acceptance flow with real API/Postgres/Redis/MinIO and fake paid providers | 1 scenario passed |
| `uv run pytest -m live_provider -q` | 3 skipped because credentials were absent |
| `swift test --package-path Packages/LadleCore` | 32 passed |
| Full Xcode test suite | 109 passed, 0 failed, 0 skipped |
| Xcode app tests | 89 passed |
| Xcode UI tests | 20 passed |
| Clean generic iOS Simulator build with signing disabled | Pass |
| Embedded Share Extension | `Ladle.app/PlugIns/LadleShare.appex` present |
| `docker compose up -d --build` | API, worker, Postgres, Redis, and MinIO started |
| `/health/live` | `live` |
| `/health/ready` | Database, Redis, and storage all `ready` |
| `uv run alembic check` in the API container | No new upgrade operations |
| `scripts/check_secrets.sh` | No high-confidence committed secret patterns |
| `git diff --check` | Pass |

The acceptance scenario covers the twelve plan-level flows in one ordered
system test: first import, cross-user cache reuse, concurrent claim
coalescing, provider fallback, visual uncertainty, private correction,
re-import safety, parallel guest limits, Apple merge, CRUD/tombstone sync,
lease takeover, and pasted-text recovery.

## Behavioral invariants rechecked

- A public cache hit clones reusable extraction data without calling caption,
  visual, or Claude providers again.
- Cache scope is the canonical source video, so separate users requesting the
  same public video share extraction work while receiving independent recipe
  ownership.
- Private, pasted-text, and correction-note imports bypass the public cache.
- Re-importing a cached video updates the intended recipe when its base
  revision is still current; otherwise it creates a hidden review candidate.
- Failed and needs-review replacements never destroy the current usable
  recipe.
- Supadata acquisition failures fall through to SoScripted. The server
  fallback adapter exists, but `yt-dlp`/`ffmpeg`/`faster-whisper` processing
  is not yet implemented or wired into the runtime.
- Missing visual evidence lowers confidence and routes ambiguous quantities to
  review rather than inventing values.
- Import reservations remain correct under duplicate, concurrent, failed, and
  cached requests.
- Post-login merge waits for any active sync and then performs a new
  cursor-zero destination sync.
- Logs, metrics, errors, and secret scanning exclude tokens, pasted text,
  correction notes, and provider credentials.

## Defects found and corrected during final integration

1. Initial re-import submissions did not transmit correction notes. The
   request contract now encrypts private text immediately and marks the job to
   bypass the public cache.
2. A cached re-import could create a second visible recipe and consume a new
   guest reservation. Cache completion now applies the replacement safely to
   the existing recipe or retains it as a hidden review candidate.
3. Duplicate and guest-limit admission failures could leave a local parsing
   job behind. The coordinator now removes rejected local jobs.
4. A post-authentication reset could coalesce into an older in-flight sync and
   retain its cursor. Reset now waits for that run and starts a distinct full
   sync; the red test observed one request at cursor 42, and the focused green
   rerun observed two requests with the second at cursor 0.
5. Seeded UI-test jobs could auto-resume through the demo service and become
   terminal before pending-state assertions. Demo polling is now explicitly
   injected and deterministic.

## Production configuration

Required production secrets and service coordinates must be supplied outside
the repository:

- core: `LADLE_ENVIRONMENT`, `LADLE_JWT_SIGNING_SECRET`,
  `LADLE_DATA_ENCRYPTION_KEY`, `LADLE_DATABASE_URL`
- queue: `LADLE_CELERY_ENABLED`, `LADLE_CELERY_BROKER_URL`,
  `LADLE_CELERY_RESULT_BACKEND`
- object storage: `LADLE_OBJECT_STORAGE_ENABLED`,
  `LADLE_OBJECT_STORAGE_ENDPOINT_URL`, `LADLE_OBJECT_STORAGE_REGION`,
  `LADLE_OBJECT_STORAGE_BUCKET`, `LADLE_OBJECT_STORAGE_ACCESS_KEY`,
  `LADLE_OBJECT_STORAGE_SECRET_KEY`
- extraction: `LADLE_WORKER_PROVIDER_MODE`, `LADLE_SUPADATA_API_KEY`,
  `LADLE_SOSCRIPTED_API_KEY`, `LADLE_ANTHROPIC_API_KEY`,
  `LADLE_ANTHROPIC_MODEL_ID`
- Apple: `LADLE_APPLE_ENABLED`, `LADLE_APPLE_BUNDLE_ID`,
  `LADLE_APPLE_TEAM_ID`, `LADLE_APPLE_KEY_ID`,
  `LADLE_APPLE_PRIVATE_KEY`
- optional enforcement/fallback: `LADLE_ATTESTATION_ENFORCED`,
  `LADLE_SERVER_MEDIA_FALLBACK_ENABLED`

Provider base URLs, timeout, quota, circuit-breaker, lease, token-lifetime,
and cache-recheck settings are documented in `Backend/.env.example`.

## Remaining external verification

- The three paid-provider smoke tests need real Supadata, SoScripted, and
  Anthropic credentials before their live behavior can be reported as passed.
- Sign in with Apple needs production Apple credentials, the final bundle ID,
  and a signed real-device run.
- App Attest enforcement needs production Apple configuration and real-device
  validation.
- The release API hostname, TLS, production database/Redis/object storage, and
  secret injection must be provisioned in the deployment environment.
- The server media/ASR backup needs a concrete processor and runtime wiring;
  its feature flag does not enable a backup by itself.

No live provider, production Apple service, or paid API was silently simulated
as verified.
