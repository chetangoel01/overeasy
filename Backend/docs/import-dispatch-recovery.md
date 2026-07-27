# Import dispatch and recovery

## Purpose

Guarantee that a committed import is recoverable when broker delivery fails,
and give repeated worker crashes a deterministic terminal outcome.

## User-visible behavior

The API returns an accepted import after its job and dispatch intent commit
together. A temporary Redis outage no longer turns that success into a 500 or
strands the job: the periodic worker sweep retries pending outbox rows. Repeating
the same idempotent submission also retries an undispatched job.

If a dispatched task disappears, maintenance waits until the configured
32-minute stale threshold, releases its expired extraction claim, and queues it
again. After three successful dispatches without a terminal result, the import
fails as `networkUnavailable` and receives a durable dead-letter record.

## Decisions

- `import_dispatch_outbox` is inserted or reset in the same transaction as
  admission and user-requested retry.
- Broker delivery occurs after commit. Delivery failure records only the
  exception class; request data and credentials never enter the outbox.
- A successful send increments `dispatch_count`. Failed sends stay pending and
  can be retried without consuming the worker-loss allowance.
- Pending rows are locked with `SKIP LOCKED`, so multiple maintenance workers
  cannot dispatch the same row concurrently.
- Celery retries explicitly transient task failures up to three times with
  exponential backoff, bounded delay, and jitter. Non-retryable failures enter
  the same terminal path immediately. Retry exhaustion and repeated worker loss
  both clear private text, release recipe capacity and claims, fail the job, and
  create `import_dead_letters`.
- Task IDs remain deterministic (`import:{job_id}`), and the orchestrator is
  idempotent if delivery is duplicated across a broker/commit failure window.

## Affected components

- `alembic/versions/0009_add_import_dispatch_outbox.py`
- `ladle/imports/outbox.py`
- `ladle/imports/admission.py`
- `ladle/imports/transitions.py`
- `ladle/worker/tasks.py`
- `ladle/api/routes/imports.py`

## Verification

Integration tests cover broker failure after commit, idempotent redispatch,
expired-claim recovery, dead-letter exhaustion, migration/model consistency,
and reservation release. Unit tests cover retry backoff, jitter, task limits,
and periodic task registration.
