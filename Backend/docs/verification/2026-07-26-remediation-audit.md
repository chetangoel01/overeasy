# Production remediation audit — 2026-07-26

## Status meanings

- **PASS** — implemented and covered by local automated or executable
  verification.
- **DEPLOY** — implementation or deployment policy exists, but the hosted
  environment must apply and prove it.
- **EXTERNAL** — requires managed-service access, production credentials, a
  signed real device, or a deployed staging hostname.

This record maps every audit requirement to evidence. It does not turn a local
policy file into a deployed control.

## P0

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Real App Attest verifier and production fail-closed injection | PASS | `AppleAppAttestVerifier`, production `Settings`, and `create_app` verify the Apple chain, nonce, App ID, environment, key, assertion, and configured verifier. Unit/integration fixtures cover cryptographic rejection. |
| Guest/import App Attest enforcement, replay/freshness/binding/revocation | PASS | Durable one-use five-minute challenges, exact request/body client data, installation/key/device binding, row-locked monotonic counters, atomic prior-key retirement on valid rotation, invalid/replayed-key device revocation, blocked refresh, and durable rejection of replacement attestation for a revoked installation are enforced. |
| Distributed guest/auth/import/recipe/sync/global rate limits | PASS | Atomic Redis multi-bucket Lua policy covers IP, installation/device, user, operation, and global dimensions; Google auth uses an equivalent isolated policy. |
| Real typed 429 with `Retry-After` | PASS | API wiring and Redis integration tests produce `rateLimited`, `retryAt`, and whole-second `Retry-After`; the staging probe exercises the real boundary. |
| Daily/monthly per-user import quota | PASS | UTC-window quota events serialize on the user row; idempotent requests do not double count and API overflow returns typed `quotaExceeded`. |
| Atomic pre-dispatch provider reservation/reconciliation/release | PASS | `ProviderUsageLedger` reserves before calls, reconciles known actual units, and releases zero-cost failures idempotently. |
| Concurrent cross-worker provider budget enforcement | PASS | PostgreSQL budget-window row locking and a real concurrent integration race admit exactly the budgeted work. |
| Explicit `UsageLimitExceeded` terminal handling | PASS | Orchestration maps it to terminal `quotaExceeded`, clears private text, releases capacity/claims, and does not strand `parsing`. |
| Complete application SSRF defense | PASS | The pinned client validates all DNS answers, pins IP plus Host/SNI, revalidates each redirect, rejects non-global and mapped addresses, restricts HTTPS/443, bounds bytes, ignores proxy environment, and covers linked pages, media, captions, oEmbed, and thumbnails. DNS rebinding, mixed answers, redirects, metadata, and IPv4-mapped IPv6 have tests. |
| Worker egress backstop | PASS | The private Mac host runs a UID-scoped default-deny gateway. Live worker probes allowed only PostgreSQL, Redis, and public HTTPS; metadata HTTP/HTTPS, RFC1918, loopback, non-443, IPv4-mapped metadata, and IPv6 were rejected with matching counters. Any replacement public host still needs equivalent control-plane egress rules. |
| Load-balancer and application request-size limits | PASS | Application streaming/declared limits and the rootless Nginx 1 MiB boundary are active. Local and tailnet 1 MiB-plus requests returned typed `413 invalidRequest`. |
| Bounded recipe graph, text, counts, nesting, complexity, decimals, durations | PASS | `RecipeDTO` enforces every requested field/list/reference/numeric/depth/node/aggregate bound; contract and iOS editor tests cover rejection and compatible fixtures. |
| Character/encryption byte-limit alignment | PASS | Import private text validates the 200,000-byte UTF-8 ceiling before encryption; multibyte boundaries and cipher limits are tested. |

## P1 — reliability and data integrity

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Heartbeat claims throughout slow worker work | PASS | A separate-session heartbeat monitor surrounds acquisition, transcription/vision provider chains, extraction, and thumbnail work; claim loss is surfaced before commit. |
| Claim duration safely exceeds heartbeat gap | PASS | Startup validation requires `heartbeat * 2 < lease`; defaults are 30 seconds and 10 minutes. |
| Aligned Celery/provider/lease/visibility/stale/shutdown limits | PASS | Soft/hard limits are 25/26 minutes, visibility 30 minutes, stale recovery 32 minutes, recipe reservation 60 minutes, and provider reservation 30 minutes. Invalid chains fail validation, including `.env.example`. |
| Explicit transient retry policy | PASS | Only timeout, connection, broker/Redis, transient database/provider, soft-limit, and lost-claim failures retry with bounded exponential backoff and jitter. Permanent validation/invariant failures dead-letter immediately. |
| Dead-letter handling | PASS | Retry/dispatch exhaustion produces durable `import_dead_letters`, terminal typed failure, private-text clearing, claim release, and capacity release. |
| Database-commit/broker-dispatch gap | PASS | Import job and outbox intent commit atomically; API post-commit delivery and the periodic `SKIP LOCKED` sweeper recover broker failure. |
| Idempotent resubmission redispatch | PASS | Pending/missing outbox state redispatches immediately; dispatched work with no live claim is recovered after the bounded live-task window rather than duplicating a newly queued task. |
| Deterministic abandoned-job recovery | PASS | A 30-second sweep requeues stale parsing work after 32 minutes, releases expired claims, and dead-letters repeated worker loss. Chaos tests prove terminal recovery. |
| Shared provider circuit breaker | PASS | Atomic Redis state shares failure counts, open windows, and recovery across workers. |
| Production fail-closed configuration | PASS | Production requires Celery/live extraction, TLS credentialed Redis/PostgreSQL, provider key, object storage, both shipped identity providers, App Attest, rate limiting, durable metrics, structured logging/tracing, managed keyring, and non-placeholder secrets. |
| Cross-setting timing validation | PASS | A model-level validator rejects every unsafe ordering and the checked-in environment example is loaded in tests. |
| Startup dependency retries | PASS | Production API retries the full readiness set 12 times; Celery retries broker startup. |
| Extended readiness | PASS | Database connectivity/head revision, broker, result backend, rate-limit/metrics Redis, storage, production configuration, and live worker ping are checked. Queue depth/age and stuck work are durable gauges with paging alerts. |
| Safe migration deployment gate and rollback compatibility | PASS | The Mac deploy runs the one-shot release migration before replacing API/worker processes, and readiness rejects non-`0011`. Repeated live deploys completed the gate at `0011`; every release migration remains additive for rollback compatibility. |

## P1 — privacy and account lifecycle

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Authenticated deletion for guests and signed-in users | PASS | Guest, Apple, and Google accounts use the same authenticated deletion endpoint and client flow. |
| Delete/anonymize associated account data and objects | PASS | Cascades remove recipes/graph, imports, sessions/hashes, devices/App Attest, identities, quota/reservations, attempts, private text, and sync state. Owned objects enter an idempotent deletion queue; the retained audit contains only keyed digests. |
| Revoke Sign in with Apple credentials | PASS | Encrypted Apple refresh credentials are revoked before database deletion; provider failure leaves the account intact and retryable. A real credential check remains under the signed-device external gate. |
| Confirmation, reauthentication, idempotency, progress, audit | PASS | Literal confirmation plus current refresh token are required; stable idempotency survives response loss and durable states/audit headers expose progress without raw identity. |
| Retention schedules for all requested data classes | PASS | Hourly sweep covers sessions, challenges, terminal jobs, private text, provider attempts, negative/invalid caches, sync changes/tombstones, deletion audits, and orphan thumbnails with bounded cleanup retry. |
| Object-storage lifecycle and orphan cleanup | DEPLOY | Database orphan queue/processor is tested. Local Compose enables versioning and applies lifecycle JSON; the non-media Mac mini profile disables object storage. Apply and age-test the same temporary, incomplete, noncurrent, and delete-marker policy on each externally managed bucket. |
| Privacy disclosure | PASS | The in-app policy documents collection, provider/hosting sharing, operational identifiers, retention, permanent guest/signed-in deletion, Apple revocation, and backup recovery behavior. |
| Managed encryption keys and rotation | PASS | Production requires an environment-supplied versioned keyring and active key ID; LPT2 embeds the ID, old/legacy ciphertext remains readable, and normal/emergency rotation is documented and tested. Confirm the production secret-manager policy and emergency drill externally. |

## P2 — operations and observability

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Durable multi-process metrics | PASS | Atomic Redis hashes share counters/histograms/gauges across API and worker recreation. |
| Protect `/metrics` | PASS | A dedicated production bearer token is mandatory and unauthenticated scans receive 404; private ingress remains recommended. |
| Structured JSON logs and safe context | PASS | API and Celery workers install the sink formatter. HTTP logs include request ID and keyed user pseudonym; worker/provider logs include job, stage, provider, retry, duration, and terminal result. |
| Sink-boundary redaction | PASS | The formatter recursively redacts sensitive keys, `SecretStr`, private import fields, and embedded bearer credentials. |
| Distributed tracing | PASS | OpenTelemetry instruments FastAPI, Celery propagation, Redis, SQLAlchemy, HTTPX, and worker/provider paths with required HTTPS OTLP in production. |
| Error reporting and required alerts | DEPLOY | Correlated JSON errors/traces and Prometheus rules cover 5xx/429, queue/stuck jobs, never-seen or stale worker/Beat, claims, provider auth/quota, spend, dependencies, migration, dead letters, and cleanup. Load the rules, connect notification sinks, and fire them in staging. |
| Production dashboards | DEPLOY | Grafana JSON has the eight required success/latency/cache/cost/retry/sync/abuse/queue views. Import and validate it against hosted metrics. |
| Managed PostgreSQL backups and PITR | EXTERNAL | The checked policy requires PostgreSQL 16+, encrypted multi-AZ daily backups, 35-day retention, cross-region copy, and seven-day PITR. Provisioning evidence is still required. |
| Real restore drill | PASS | Real PostgreSQL 16.14 `pg_dump` to empty-server `pg_restore` restored two rows with identical source/target SHA-256. Repeat against the managed backup/PITR control plane. |
| Redis durability and failure behavior | PASS | Redis uses AOF every second, hourly snapshots, no eviction, and persistence-error write refusal. Redis and full Docker Desktop restart drills retained data, restored API readiness, and reconnected the worker. Celery messages are persistent and PostgreSQL outbox recovers queue loss; this single-host profile accepts host loss as its documented residual risk. |
| Incident runbooks | PASS | Provider outage, Redis loss, database failover, secret rotation, runaway spend, stuck migration, worker rollback, and account deletion runbooks exist. |
| Service-level objectives | PASS | A 28-day SLO/error-budget policy defines availability, import success/latency, sync/queue latency, deletion, and recovery objectives. |

## P2 — container and supply chain

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Immutable Python/uv base images | PASS | Both images use multi-platform SHA-256 digests. |
| Controlled OS packages | PASS | Debian snapshot date and exact `ca-certificates`/`ffmpeg` versions are pinned. |
| Docker `HEALTHCHECK` | PASS | API readiness uses the hosting `PORT`; worker overrides with Celery ping. |
| Read-only root and bounded temporary storage | PASS | Runtime uses a read-only root and 256 MiB tmpfs. |
| CPU/memory/PID/FD/temp/file-size limits | PASS | Compose runtime and tests enforce one CPU, 1 GiB, 256 PIDs, bounded FDs/tmpfs/file size. Preserve or tighten these on the host. |
| Capabilities and seccomp/AppArmor | PASS | All capabilities and privilege escalation are dropped; the migration manifest declares `RuntimeDefault` seccomp. Docker inspection on the Mac mini confirmed the built-in seccomp profile plus the expected read-only, capability, and no-new-privileges settings on API, worker, and Beat. Preserve these controls on any replacement host. |
| Final OS and Python image scan | PASS | CI run `30237849303` built commit `c876fa6` for Linux/amd64 and passed HIGH/CRITICAL OS/Python scans for the application, Mac ingress, and worker-egress images. |
| SBOM, provenance, and image signing | DEPLOY | The current candidate generated a valid SPDX 2.3 SBOM with 390 packages and 6,869 relationships. Main-branch BuildKit SBOM/provenance plus keyless digest signing are configured; publish/sign the final main digest through GitHub OIDC. |
| Production-context exclusions | PASS | Git, env files, tests/docs/scripts/deploy/load, Compose, cookies, caches, local DBs, and evaluation artifacts are excluded and layer-tested. |
| Configurable S3 addressing | PASS | `auto`, `path`, and `virtual` configure internal and public clients; Compose uses path and Railway can use virtual. |
| Configurable `PORT` | PASS | Validated `PORT` entrypoint supports Render/Railway and the image health check follows it. |

## P2 — CI/CD and verification

| Requirement | Status | Evidence and remaining gate |
| --- | --- | --- |
| Ruff, strict mypy, non-live tests, migrations, secrets, dependency/container scan, diff CI | PASS | Pinned-SHA GitHub workflow defines every gate; local equivalents have passed. |
| Pytest at least 9.0.3 | PASS | Lock selects pytest 9.1.1 and the complete suite uses it. |
| Automatic model/migration consistency | PASS | Alembic `check`, empty upgrade, constraint tests, and explicit CI gate cover metadata drift. |
| Tests for new controls | PASS | Dedicated App Attest, rate-limit, quotas/budgets, production settings, body/graph/SSRF, deletion/retention, outbox/heartbeat, observability, and container policy suites exist. |
| Load tests | PASS | Isolated k6 scenarios passed guest creation, import bursts, sync polling, and maximum graphs; PostgreSQL concurrency tests cover budget enforcement. |
| Worker-kill/broker-outage tests | PASS | Isolated SIGKILL and Redis-loss scenarios recovered to deterministic success. |
| Credentialed live-provider smoke | EXTERNAL | A text-only live OpenRouter extraction passed on the Mac mini. Supadata and SoScripted remain intentionally uncalled under the explicit no-video scope, and no Anthropic credential is configured. |
| Production Apple real-device validation | EXTERNAL | A physical paired iPhone is visible, but this Mac has no signed-in Xcode team or provisioning profiles for the app, tests, and share extension. Add the production Apple account and profiles, then validate the final signed build. |
| App Attest real-device matrix | EXTERNAL | A gated XCTest now exercises real Apple attestation, installation binding, a valid assertion, replay, valid key rotation with prior-key retirement, invalid-assertion revocation, and durable rejection of replacement attestation. Its generic iOS device path compiles, and an isolated enforcing Mac endpoint rejected unattested guests. Execution on the paired iPhone is blocked by the missing Xcode account/profiles; rerun only against a disposable isolated database in the production App Attest environment afterward. |
| Build and scan exact production image | PASS | CI run `30237849303` rebuilt and scanned commit `c876fa6` for Linux/amd64, then retained the application and both Mac infrastructure SPDX SBOM artifacts. Runtime hardening, migration, ingress, and egress were exercised on the Mac arm64 deployment. |
| Staging migration/rollout/rollback/restore/Redis/worker/provider drills | EXTERNAL | The private Mac staging host passed migration, repeated rollout, rollback to `22de9e9`, roll-forward to `c876fa6`, fresh off-host PostgreSQL restore, worker replacement, and Redis persistence/reconnect. The earlier text-only provider smoke passed. Managed PITR/failover and a credential-safe live provider-outage drill remain external. |
| Final external security check | EXTERNAL | The private tailnet hostname passed `verify_staging.py` for TLS, headers, secret leakage, dependencies, hidden endpoints, authentication, and request size. A live local-isolated probe produced typed `429` plus `Retry-After`, and worker egress canaries passed. The byte-exact real-device App Attest/metadata assertion remains external. |

## Final local verification snapshot

- Backend quality gates: Ruff formatting and lint passed, strict mypy passed
  for 108 source files, and the latest complete non-live suite passed with 467
  tests, 3 credential-gated skips, and 2 live/chaos deselections.
- Supply chain: the committed-secret scan found no high-confidence patterns,
  `pip-audit` found no known vulnerabilities, and digest-pinned Trivy found
  zero fixable HIGH/CRITICAL findings.
- Current exact private deployment: commit `c876fa6` on Docker Desktop. CI run
  `30237849303` passed Ruff, strict mypy, 470 non-live tests, migration
  consistency, a real PostgreSQL restore, dependency and secret scans, exact
  application/ingress/egress image scans, and fresh SPDX SBOM generation.
- Prior exact-image runtime: an empty PostgreSQL 16 database upgraded through
  revision `0011`; readiness reported database, broker, result backend,
  rate-limit Redis, metrics Redis, storage, configuration, and worker as
  ready.
- Runtime hardening: the probe used a read-only root, 256 MiB no-exec temp
  storage, all capabilities dropped, no-new-privileges, one CPU, 1 GiB memory,
  256 PIDs, and bounded file descriptors and file size. Docker health and
  liveness passed, unauthenticated metrics returned 404, authenticated metrics
  returned 200, and a 1 MiB-plus request returned typed 413.
- Data recovery: a PostgreSQL 16.14 dump/restore into an empty server retained
  two rows with matching source/target SHA-256
  `8dc3c7e28f5cc227f54029d278de104cf4854f8838a396213c6081298a091dbb`.
- Client compatibility: LadleCore passed 37 tests, the iOS Ladle scheme passed
  152 tests, and Release builds passed for the app and Share Extension.
- Signed-device readiness: the full real-device App Attest matrix is encoded in
  a credential-gated XCTest and its physical-device branch compiles. The
  available paired iPhone could not run it because Xcode has no authenticated
  Apple team or provisioning profiles; no build was installed on the phone.
- Private staging: the Mac mini runs commit `c876fa6` with all
  video/audio/frame paths disabled. TLS/security/exposure verification, typed
  live 413/429 boundaries, real client-IP forwarding, restart recovery, and
  infrastructure egress canaries pass. Rollback/roll-forward retained revision
  `0011` and both users; the fresh post-edge dump restored off-host with two
  users and two recipes. The earlier text-only OpenRouter import passed; it was
  not repeated after the provider credentials became subject to mandatory
  rotation.
- Resilience and load: isolated worker-kill and Redis-outage recovery passed;
  the deployed idle-worker replacement and Redis AOF persistence/reconnect
  drills also passed, while the local load run completed 3,277 checks with no
  unexpected failures.

## Release conclusion

All discovered in-repository P0/P1 implementation gaps are closed. Public
exposure remains blocked until the **DEPLOY** P0/P1 controls and signed-device,
credentialed, managed-service, rollout, and external security gates above have
passing evidence. P2 hosted controls are likewise required before describing
the service as operationally production-grade.
