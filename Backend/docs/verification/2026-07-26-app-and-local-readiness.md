# App compatibility and local release readiness — 2026-07-26

## Purpose

Verify that the production-readiness backend changes preserve the iOS client
contract and that the exact scanned backend image can migrate, start, and
report ready under the intended container restrictions.

## iOS compatibility

- `swift test --package-path Packages/LadleCore`: 37 tests passed across 8
  suites.
- `xcodebuild test` for the `Ladle` scheme on an iPhone 17 Pro simulator
  running iOS 26.5: 152 tests passed with no failures or skips.
- Release build for the `Ladle` scheme on a generic iOS device: passed with
  code signing disabled. This build includes the embedded Share Extension.
- Independent Release build for the `LadleShare` target: passed with code
  signing disabled.

No shared-contract, app-flow, or Share Extension regression surfaced.

## Backend release checks

- Production configuration, security headers, health probes, migration
  consistency, and migration-aware readiness: 58 focused tests passed.
- Real PostgreSQL restore drill:
  - PostgreSQL source and restore version: 16.14;
  - two rows restored into an empty server;
  - source and restored SHA-256 checksums both
    `8dc3c7e28f5cc227f54029d278de104cf4854f8838a396213c6081298a091dbb`.
- Exact previously scanned image:
  `sha256:fb75e71d15e2267f08097dd1dd6725822a3cd8ae333a3ca02c8b6d51e7d84c2e`.
  - applied every migration from `0001` through head revision `0011` to a
    disposable PostgreSQL instance;
  - returned HTTP 200 from liveness and readiness, with database, broker,
    result backend, metrics Redis, object storage, worker, and configuration
    all ready;
  - reached Docker health `healthy` while running as `ladle` with a read-only
    root filesystem, all capabilities dropped, `no-new-privileges`, 256 PIDs,
    1 GiB memory, and one CPU;
  - hid `/metrics` without its bearer token and served it with the token;
  - rejected a declared request larger than 1 MiB with HTTP 413 and the typed
    `invalidRequest` error;
  - emitted the expected request ID and security headers.

## Migration-gate observation

The long-running developer database was still at revision `0004`. The release
image correctly returned not-ready with only the database probe unavailable.
That database was not modified. The passing smoke used a disposable database
and the release image's one-shot migration command, demonstrating why the
deployment migration gate must complete before new API or worker instances
receive traffic.

Both disposable smoke containers were removed after verification. The normal
developer Compose services and persistent volumes were left running and
unchanged.

## Remaining external gates

Local verification does not replace the credentialed and hosted checks already
listed in the CI/chaos/load verification record: signed-device Apple and App
Attest flows, live providers, managed backup/PITR, staged rollout and rollback,
deployed-host TLS and egress checks, and registry publication/signing.
