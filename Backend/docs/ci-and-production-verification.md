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

Every third-party GitHub Action is pinned to a full commit SHA. In particular,
the image scan uses the post-incident Trivy Action v0.36.0 commit rather than a
mutable or pre-0.35 tag; Dependabot proposes reviewed SHA updates.

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
real-device token plus assertion headers for the exact request, it also
attempts a cloud-metadata import URL and requires rejection.

The script complements, but cannot replace, the staging network-policy canary,
managed backup/PITR restore, Apple production credentials, and real-device App
Attest matrix. Store every run's hostname, image digest, migration revision,
time, and result in `docs/verification`.
