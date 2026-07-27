# Backend CI, image, chaos, and load verification — 2026-07-26

## Scope

Verify the production-gate implementation, exact Linux image, worker/broker
recovery, and abuse/capacity scenarios before the final full backend and iOS
compatibility pass.

## Results

- Locked runtime and development dependencies: `pip-audit` found no known
  vulnerabilities.
- Repository secret pattern check: no high-confidence committed secrets.
- CI supply chain: every third-party Action is pinned to a 40-character commit
  SHA. Trivy Action is the patched v0.36.0 commit; the load runner is k6 1.7.1
  pinned by image digest.
- Worker `SIGKILL` during active extraction: replacement worker reclaimed and
  completed the import; 1 test passed in 118.36 seconds.
- Redis outage during active extraction: Redis, worker, and Beat restart
  produced a successful terminal import; 1 test passed in 40.99 seconds.
- Isolated k6 run:
  - 3,277 checks, all successful;
  - 3,277 HTTP requests with no unexpected failure;
  - approximately 83.5 requests/second;
  - p95 452.5 ms and p99 573.72 ms;
  - guest creation, import bursts, sync polling, and maximum recipe graph
    scenarios all passed.
- Final production image:
  - local image ID
    `sha256:fb75e71d15e2267f08097dd1dd6725822a3cd8ae333a3ca02c8b6d51e7d84c2e`;
  - Linux/amd64, 333,760,341 compressed bytes;
  - non-root UID 10001;
  - no uv build cache or load harness in runtime layers;
  - digest-pinned Trivy 0.72.0 found zero fixable high/critical Debian or
    Python vulnerabilities;
  - SPDX JSON SBOM generated with 384 packages (867,170 bytes).

The first diagnostic load run used one account for both maximum-graph writes
and sync polling. That made every poll return several megabytes and failed the
latency threshold despite all functional checks passing. Scenario accounts are
now isolated, so the passing run measures endpoint capacity without
cross-scenario data amplification.

Only the named `ladle-chaos-recovery` and `ladle-load-verification` Compose
projects and their temporary volumes were destroyed. The developer's normal
Compose stack was not altered.

## Still requires an external environment

These gates cannot be truthfully completed in a local fake-provider stack:

- run `scripts/verify_staging.py` against the deployed HTTPS staging hostname,
  including the real 429 and metadata-egress probes;
- run the credential-gated provider smoke tests;
- validate Sign in with Apple and App Attest on a signed real device;
- verify managed PostgreSQL backup/PITR and a staging restore;
- exercise staging migration, rollout, rollback, Redis restart, worker
  replacement, and provider outage;
- publish, rescan, attest, and sign the main-branch image digest using GitHub
  OIDC.

Record the staging hostname, image digest, migration revision, credentials
matrix, and results in a separate dated verification record.
