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
only after the scan passes. Deployment consumes the signed digest, never a
mutable tag.

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

## Scheduled capacity and chaos checks

`load/k6-production.js` exercises four independent scenarios: guest creation,
import bursts, sync polling, and maximum-size recipe graphs. It targets only an
isolated fake-provider stack with App Attest disabled; it is a capacity test,
not an attestation bypass for any public environment. The concurrent
PostgreSQL budget-reservation integration test separately proves serialized
provider spending under competing workers.

The runner is k6 1.7.1, selected for its 2026 gRPC security update and pinned by
container digest.

`tests/chaos/test_worker_and_broker_recovery.py` runs against its own named
Compose project and isolated port 42112, without altering a developer's normal
stack. One scenario sends SIGKILL while a fake import is actively
acquiring, replaces the worker, and requires the job to terminate successfully.
The other removes Redis during active work, restores the broker, replaces
worker/Beat, and requires deterministic terminal state. The fake delay exists
only to create a reliable failure window.

## Staging gate

Run:

```bash
cd Backend
.venv/bin/python scripts/verify_staging.py https://staging-api.example \
  --exercise-rate-limit
```

The external probe verifies TLS, readiness, security headers, hidden
documentation/metrics endpoints, typed authentication, application request
limits, real 429/`Retry-After`, and response secret leakage. With a signed
real-device token, assertion headers, and the exact JSON bytes used to create
that assertion, it also attempts a cloud-metadata import URL and requires
rejection:

```bash
.venv/bin/python scripts/verify_staging.py https://staging-api.example \
  --access-token "$STAGING_ACCESS_TOKEN" \
  --attestation-headers /secure/metadata-assertion-headers.json \
  --attested-request-body /secure/metadata-request-body.json
```

The request-body file must contain the exact compact JSON bytes signed by App
Attest, including a valid `jobID` and
`"sourceURL":"http://169.254.169.254/latest/meta-data"`. Reformatting the file
after signing invalidates the assertion by design.

The script complements, but cannot replace, the staging network-policy canary,
managed backup/PITR restore, Apple production credentials, and real-device App
Attest matrix. Store every run's hostname, image digest, migration revision,
time, and result in `docs/verification`.

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
