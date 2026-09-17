# CI and production verification

## Purpose

Turn the readiness checklist into repeatable release gates and destructive
recovery checks instead of relying on an operator's memory.

## Pull-request gates

`.github/workflows/backend-ci.yml` runs Ruff formatting and lint, strict mypy,
all non-live/non-chaos tests, explicit model/migration consistency, a real
PostgreSQL dump/restore, dependency auditing from a frozen export of every uv
lock group, full-history secret scanning, and `git diff --check`.

The image job builds the exact Dockerfile for Linux amd64, scans both OS and
Python packages for fixable high/critical findings, and retains an SPDX JSON
SBOM. A main-branch release is rebuilt with BuildKit SBOM and maximum
provenance attestations, rescanned by immutable digest, and keylessly signed
only after the scan passes. The single-host VPS currently builds the exact Git
archive it receives; the published image remains available when moving builds
off the host becomes worthwhile.

The same job also builds and scans the Mac mini worker-egress and ingress
images from pinned base digests. Both final auxiliary images must have zero
fixable HIGH/CRITICAL findings, and their SPDX SBOMs are retained together.
This prevents a defensive proxy or firewall sidecar from weakening the scanned
application image's supply-chain posture.

Trivy is explicitly limited to its vulnerability scanner in the image jobs.
Repository secrets remain covered by the separate full-history gitleaks gate;
this separation prevents known public API identifiers embedded in upstream
packages from being misclassified as repository secret leaks.

Every third-party GitHub Action is pinned to a full commit SHA. In particular,
the image scan uses the post-incident Trivy Action v0.36.0 commit rather than a
mutable or pre-0.35 tag; Dependabot proposes reviewed SHA updates. All
JavaScript actions used by the workflow are maintained Node 24 releases,
avoiding GitHub's deprecated Node 20 action runtime.

Pytest is constrained to 9.0.3 or newer; the current lock selects 9.1.1.
The test client uses Starlette's maintained HTTPX2 path, avoiding the deprecated
legacy HTTPX adapter.

The September 8 merge gate found five advisories in the locked HTTPX2 and
HTTPCore2 2.9.1 packages. `uv.lock` now selects 2.12.0 for both; the frozen
all-groups dependency audit reports no known vulnerabilities. All 1,107 backend
tests, Ruff formatting/lint, and strict mypy pass with the updated lock. Existing
API and provider tests cover this dependency-only update, so it adds no new test.

## Test maintenance

Keep a test when it protects a distinct behavior, regression, edge case, or
contract. Prefer extending an existing test when it already covers the change.
Do not copy dependency versions, UI wording, settings defaults or design-token
values, the text of scripts, config or production source, or arbitrary
file/line counts into tests. Each parametrised case must reach a branch,
boundary or field no sibling reaches. Immutable dependency pins, isolation
rules, and release gates remain useful contracts; the exact selected version
belongs in its configuration. Do not combine unrelated assertions merely to
reduce the reported test count.

The September 17 audit counted 1,143 backend cases across 865 test functions;
278 cases were parameter expansions. The feedback fixes added 36 cases to the
1,107-case baseline. The initial pruning pass removed six low-value tests:
Grafana panel titles, dashboard markup presence, a constructor type assertion,
and three static validator/report snapshots. It also removed duplicated Action
versions/counts, build-cache mount counts, and the VPS script file/line budget;
uv and iptables checks now verify pinning without copying selected versions.
No application behavior or CI gate changed. Authentication, unsafe-URL handling,
import recovery, nutrition, and real infrastructure tests remain in place.

The validator/report UI remains subject to browser review when changed, rather
than treating source-string matches as proof of rendering or accessibility.
This was a targeted pruning pass, not a claim that every remaining test has
been audited. No new test was needed for deleting tests and updating guidance.

Verification: 89 focused tests pass; the full default suite passes all 1,137
cases in 25.59 seconds, with the same ten Testcontainers deprecation warnings.
Ruff formatting/lint, strict mypy, and `git diff --check` pass. App code did not
change, so this cleanup did not repeat the already-passing app suites.

### September 17 backend cleanup

A second pass the same day applied a read-only audit of the whole backend suite
and then went past it. The default selection went from 1,141 cases in 867 test
functions to 1,010 in 800. Removed:

- 11 tests that copied settings defaults, proved that pydantic-settings reads
  the environment, or restated a validator every `Settings()` already runs;
- 10 text greps of deploy scripts, Compose files and an alert-rules file that
  nothing loads;
- 56 parametrised cases that reached a branch a sibling already reached;
- 13 exact or strict-subset duplicates, 6 fixture or schema echoes, and 3
  source or signature inspections;
- 33 more beyond the audit: deploy tests that restated Compose files whose
  mistakes fail the deploy loudly (required OAuth and USDA variables, gateway
  aliases, local data-service flags), argument and file plumbing of the
  evaluation and pipeline-validator scripts, and cross-layer or same-branch
  repeats in the API, extraction, contract and nutrition tests.

Sound tests kept their behaviour check and lost the copy around it: Swagger
prose, table and shelf wording, literal counts, `isinstance` lines, a CSP
literal repeated in three files, and Compose values restated beside the
deploy posture checks. Five tests could not fail for the reason they claimed
and were fixed: the link fetcher's private-address and redirect tests only ever
reached the scheme check, a supplied-unit test never reached its guard, a
Substack ranking test was decided by sitemap order, and the local-stack test
checked one service's ports rather than every published one. A worker-builder
test asserted the default model id and now sets a distinct one. A production
dashboard-token test that tripped the signing-secret check first was removed;
the settings matrix case does reach the dashboard branch. The golden round trip
gained `discover-page.json`, which only the app had been decoding.

Three settings nothing read — `frame_analysis_enabled`,
`thumbnail_analysis_enabled` and `server_media_fallback_enabled` — were removed
with their Compose and env-example lines. `Settings` ignores unknown keys, so a
deployed `.env` that still sets them loads unchanged.

Kept on purpose: SSRF and URL-safety matrices, auth and claims, rate limits and
quotas, privacy and retention, migrations, golden fixtures and recipe limits,
the fail-closed production-settings matrices, import retry and recovery
(including the Celery late-acknowledgement settings), sync conflicts, and the
admin backfills still to run in production. The audit's trims inside the #111
matching regressions were declined for `cardamom ground` and the whole-milk and
ground-beef safeguards. Deploy keeps the egress allow-list, edge headers and
hidden diagnostics, sandboxing and loopback publishing, fail-closed VPS
defaults, the migration gate, CI's security gates and SHA pins, and the chaos
timing pins. Evaluation scoring and model-comparison logic stay because a wrong
threshold does not fail loudly.

Verification: each group's files, then `uv run pytest` before every commit;
`ruff check`, `ruff format --check`, `mypy --strict ladle` and
`git diff --check` pass. Each of the five fixed tests was run with the guard it
names disabled, and failed.

## Scheduled capacity and chaos checks

`load/k6-production.js` exercises four independent scenarios: guest creation,
import bursts, sync polling, and maximum-size recipe graphs. It targets only an
isolated fake-provider stack with App Attest disabled; it is a capacity test,
not an attestation bypass for any public environment. The concurrent
PostgreSQL budget-reservation integration test separately proves serialized
provider spending under competing workers.

The runner is k6 1.7.1, selected for its 2026 gRPC security update and pinned by
container digest.

The workflow starts that stack with `docker compose up -d --build` and then
polls `http://127.0.0.1:4112/health/ready` for up to 300 s before k6 runs;
`up -d` alone returns when the containers exist, and k6's `setup()` then
reached a cold API. Compose's own `--wait` is not used because the runner's
Compose 2.38.2 rejects `beat`'s disabled healthcheck. On a non-zero exit the
step prints `docker compose ps -a` and the `api` and `worker` logs before
tearing the stack down.

`tests/chaos/test_worker_and_broker_recovery.py` runs against its own named
Compose project and isolated port 42112, without altering a developer's normal
stack. One scenario sends SIGKILL while a fake import is actively
acquiring, replaces the worker, and requires the job to terminate successfully.
The other removes Redis during active work, restores the broker, replaces
worker/Beat, and requires deterministic terminal state. The fake delay exists
only to create a reliable failure window.

`deploy/chaos/docker-compose.chaos.yml` pins every provider timeout that
`Settings.validate_worker_timing` orders below its 12 s soft task limit, and
`tests/unit/deploy/test_local_stack_policy.py` builds `Settings` from those
pins, so a new timeout cannot reach the drill unpinned and crash the stack at
startup. When `/health/ready` never answers, the test prints the last answer
it received, `docker compose ps -a` and the `api`, `worker` and `beat` logs
before failing.

## Staging gate

Run:

```bash
cd Backend
.venv/bin/python scripts/verify_staging.py https://staging-api.example \
  --staging-access-key-file /secure/staging-access-key \
  --exercise-rate-limit
```

The external probe verifies TLS, readiness, security headers, hidden
documentation/metrics endpoints, typed authentication, application request
limits, real 429/`Retry-After`, and response secret leakage. When a staging
access-key file is provided, every normal request carries
`X-Ladle-Tunnel-Key`; separate liveness probes without the header and with a
fixed, credential-independent incorrect value must both return 404. Surrounding
spaces and tabs are stripped from the key file; the remaining value must be
non-empty visible ASCII without whitespace. Newlines, control characters,
non-ASCII, and invalid bytes are rejected without including the value in the
error. The script intentionally has no option for passing the secret directly
on the command line.

With a signed real-device token, assertion headers, and the exact JSON bytes
used to create that assertion, the probe also attempts a cloud-metadata import
URL and requires rejection:

```bash
.venv/bin/python scripts/verify_staging.py https://staging-api.example \
  --staging-access-key-file /secure/staging-access-key \
  --access-token "$STAGING_ACCESS_TOKEN" \
  --attestation-headers /secure/metadata-assertion-headers.json \
  --attested-request-body /secure/metadata-request-body.json
```

The request-body file must contain the exact compact JSON bytes signed by App
Attest, including a valid `jobID` and
`"sourceURL":"http://169.254.169.254/latest/meta-data"`. Reformatting the file
after signing invalidates the assertion by design.

The script complements, but cannot replace, a real backup restore, Apple and
Google production credentials, and the real-device App Attest matrix. Store
every run's hostname, image digest, migration revision, time, and result in
`docs/verification`.

## Real-device App Attest gate

`AppAttestClientTests.testLiveRealDeviceEnforcesBindingReplayRevocationAndRotation`
is excluded from ordinary simulator runs. Against an App-Attest-enforcing
HTTPS environment, it uses Apple's real device service to prove:

- attestation and installation binding;
- a valid sensitive-request assertion;
- rejection of the same assertion/challenge replay;
- valid key rotation with retirement of the prior key;
- invalid-assertion device/key revocation; and
- rejection of refresh and replacement-key attestation after revocation.

It uses an unsupported HTTPS import source so no provider or media job is
dispatched. The invalid-assertion case deliberately leaves its installation and
test account revoked, so run it only on a physical device against a dedicated
isolated database and destroy that database after the run. Never point this
test at a shared staging or production database. The device needs the matching
App Attest environment and a signed provisioning profile:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'id=<physical-device-udid>' \
  -only-testing:LadleTests/AppAttestClientTests/testLiveRealDeviceEnforcesBindingReplayRevocationAndRotation \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<apple-team-id> \
  CODE_SIGN_STYLE=Automatic \
  APP_ATTEST_ENVIRONMENT=development \
  LADLE_API_BASE_URL=https://attest-staging.example \
  'OTHER_SWIFT_FLAGS=$(inherited) -DLADLE_LIVE_APP_ATTEST'
```

The test's device code path is compile-checked without signing using a generic
iOS `build-for-testing`. A passing production claim still requires rerunning
against the production App Attest environment and final signed app identity in
another disposable isolated environment.

## September 17 registry repair

Fresh CI workers could no longer pull `minio/minio` from Docker Hub, while
local runs continued to pass using an old cached image. The thumbnail storage
test and both Compose manifests now use the publisher's
[Quay registry](https://github.com/minio/minio/blob/master/helm/minio/values.yaml),
pinned to the April 22, 2025 release already used by Compose and its verified
multi-platform digest. The test no longer inherits Testcontainers' implicit
2022 default. Private unsigned reads, signed reads, content type, and deletion
remain covered by the existing integration test. No storage volumes or
production services were changed during this repair.

Verification: the original GitHub run failed while pulling the removed image.
After switching registries, all 1,107 backend tests pass, including the real
private-thumbnail round trip. Formatting, lint, and strict type checks pass.
The Quay manifest was checked for both amd64 and arm64 support before pinning.
