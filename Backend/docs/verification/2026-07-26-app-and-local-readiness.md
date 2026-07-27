# App compatibility and local release readiness — 2026-07-26

## Purpose

Verify that the production-readiness backend changes preserve the iOS client
contract and that the exact scanned backend image can migrate, start, and
report ready under the intended container restrictions.

## iOS compatibility

- `swift test --package-path Packages/LadleCore`: 37 tests passed across 8
  suites.
- `xcodebuild test` for the `Ladle` scheme on an iPhone 17 Pro simulator
  running iOS 26.5: 152 tests passed with no failures. The only skip is the
  compile-gated test that requires Apple's real App Attest service and a
  signed physical device.
- Release build for the `Ladle` scheme on a generic iOS device: passed with
  code signing disabled. The shared scheme explicitly builds `LadleShare`, and
  the resulting app contains an arm64 `com.ladle.ios.share` extension.

No shared-contract, app-flow, or Share Extension regression surfaced.

The project intentionally has no standalone `LadleShare` scheme. A raw
target-only Xcode invocation does not resolve the local `LadleCore` package and
is not a supported release path; the shared `Ladle` scheme is the archive and
distribution path and compiled both products successfully.

## Final Mac mini regression pass

After the private staging profile moved to commit `e9e07c7`:

- the tailnet readiness endpoint returned `200` with database, broker, Celery
  result backend, worker, Redis-backed rate limits and metrics, and
  configuration ready;
- a fresh text-only live OpenRouter import produced a ready Simple Tomato Toast
  recipe with four ingredients and three steps, fetched it, and permanently
  deleted the smoke account;
- object storage and all video/audio/frame processing remained disabled;
- LadleCore again passed 37 tests, while the Ladle simulator run passed all 152
  ordinary app/UI tests and skipped only the explicit real-device App Attest
  gate.

GitHub Actions run `30234296154` also passed Ruff, strict mypy for 108 source
files, 467 non-live tests with the intentional live/chaos exclusions, migration
consistency, a real PostgreSQL restore, dependency and secret scanning, the
Linux/amd64 image vulnerability scan, and SBOM generation.

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

## Mac mini infrastructure regression — 2026-07-27

The app/backend contract did not change after the 37 LadleCore and 152 iOS test
passes above. The final changes were isolated to the Mac deployment profile and
were verified again on commit `c876fa6`:

- the restored database remained at revision `0011` with both users after
  repeated deploys and a Docker Desktop restart;
- API, worker, Beat, Redis, PostgreSQL, edge, and worker-egress recovered
  automatically and readiness returned green locally and over Tailscale;
- the HTTPS staging verifier passed TLS, headers, secret leakage, dependency,
  exposed-endpoint, authentication, and 1 MiB request-boundary checks;
- a live rate-limit probe returned typed `429` plus `Retry-After` and deleted
  its temporary account, leaving the user count unchanged;
- live worker probes allowed dependencies/public HTTPS and rejected metadata,
  private, loopback, non-HTTPS, IPv4-mapped, and IPv6 destinations;
- all video/audio/frame processing remained disabled.

The exact current app pass then completed with:

- 37 LadleCore tests passed;
- 128 app unit/integration tests executed with zero failures and only the
  explicit signed-device App Attest test skipped;
- 25 UI tests passed across accessibility, account deletion, cooking, editing,
  import recovery, library, nutrition/Health export, and recipe detail flows;
- the generic-device Release build passed and embedded `LadleShare.appex`.

No app or Share Extension regression surfaced from the Compose, Nginx,
firewall, LaunchAgent, CI-policy, and documentation changes.
