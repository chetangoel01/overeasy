# Production startup and migration gate

## Purpose

Prevent a partially configured or schema-mismatched release from accepting API
traffic or worker jobs.

## User-visible behavior

A production process refuses to start unless Celery, live extraction, TLS Redis
and PostgreSQL, object storage, App Attest, rate limiting, and both identity
providers shipped in the iOS app are configured. Startup retries transient
dependency failures. After startup, readiness continues checking the database
revision, broker, result backend, rate-limit Redis, object storage, and at least
one worker.

## Deployment gate

Use the exact immutable image digest intended for the API and worker:

1. Replace `ladle-backend:release` in
   `deploy/kubernetes/migration-job.yaml` with that digest.
2. Apply the one-shot Job and wait for successful completion.
3. Roll out worker and API Deployments only after the Job succeeds.
4. Keep the previous application version compatible with the additive schema
   through current head `0012` during the rollout. If that is not possible, use
   a two-release expand/migrate/contract sequence.
5. Readiness rejects any pod whose expected migration revision (`0012`) is not current,
   preventing it from receiving service traffic.

The local Compose stack uses the same ordering: its `migrate` service must
complete before API, worker, or Beat starts.

## Decisions

- Production Redis endpoints must use `rediss://` with non-placeholder
  credentials.
- PostgreSQL must use the psycopg driver, credentials, and a TLS `sslmode`.
- Provider and object-storage HTTP endpoints must use HTTPS.
- Object storage, live worker mode, an extraction credential, App Attest, and
  distributed rate limiting are mandatory in production.
- Apple and Google sign-in are visible in the shipped iOS account flow, so
  production requires both backends. The Apple audience must match the App
  Attest bundle ID and its private key must be non-placeholder.
- Startup tries dependencies 12 times at five-second intervals, while readiness
  remains a continuous deployment signal.

## Verification

Unit tests cover each fail-closed setting, the checked-in example environment's
complete timing chain, worker availability, and bounded startup retries.
Integration tests change `alembic_version` to prove readiness rejects a
migration mismatch. A manifest test ensures the migration gate stays one-shot,
bounded, and explicit.
