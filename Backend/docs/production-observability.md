# Production observability

## Purpose

Make API and worker behavior observable across replicas and restarts without
putting private recipe or authentication data in telemetry.

## Runtime behavior

- Counters, histograms, and operational gauges use atomic Redis hashes shared
  by API and worker processes. Redis persistence retains them across process
  restarts.
- `/metrics` is hidden unless the dedicated bearer token matches. It also emits
  bounded readiness gauges for the database/migration, Redis roles, storage,
  configuration, and worker.
- HTTP and import latency use Prometheus histograms. Metrics cover import
  outcomes, cache disposition, provider outcomes/cost, worker retries, sync
  conflicts/resets, rate-limit rejection policy, queue health, stuck jobs,
  dead letters, claim churn, and cleanup failures.
- Celery's ready and periodic heartbeat signals update the durable
  worker-liveness gauge even when no imports are running. Beat liveness advances
  only when its scheduled maintenance task is received, so the two absence
  alerts remain independent.
- Every API and Celery worker log line is JSON. The worker installs the same
  formatter through Celery's production logging signal instead of accepting
  Celery's default plain-text root logger. The formatter—not individual
  callers—redacts sensitive keys, `SecretStr` values, bearer credentials, and
  private import fields. Request ID, pseudonymous job ID,
  stage/provider/retry context, duration, and terminal result are structured
  fields.
- OpenTelemetry emits W3C trace context through FastAPI, Celery, Redis,
  SQLAlchemy, HTTPX provider calls, and the worker. The production OTLP endpoint
  must use HTTPS.

The OpenTelemetry Python SDK and FastAPI instrumentation are pinned to the
current compatible 1.44.0/0.65b0 release family documented by the
[official Python guide](https://opentelemetry.io/docs/languages/python/) and
[FastAPI instrumentation package](https://pypi.org/project/opentelemetry-instrumentation-fastapi/).

## Deployment

1. Provision a persistent, no-eviction Redis database for metrics and set
   `LADLE_DURABLE_METRICS_ENABLED=true`.
2. Inject a random 32-byte-or-longer `LADLE_METRICS_AUTH_TOKEN` into both
   Prometheus and the API. Never expose it to browsers or the app.
3. Deploy the collector configuration in
   `deploy/observability/otel-collector.yaml` on private networking and inject
   its upstream endpoint/token.
4. Load `prometheus-rules.yaml` and route `severity=page` to the on-call page
   channel and `severity=ticket` to the incident queue.
5. Import `grafana-dashboard.json`, then set provider-spend thresholds to the
   configured daily limit rather than leaving the default 800-unit warning.

## Alerts and first response

- **5xx / dependency / migration:** stop rollout, inspect readiness and the
  matching trace, and roll back only application code that remains compatible
  with the current migration.
- **429:** split by `policy`; global or IP bursts indicate abuse, while user
  import limits may be expected cost control.
- **Queue / stuck / worker / Beat:** verify worker and Beat heartbeats, broker
  persistence, visibility timeout, and claim/outbox recovery before scaling.
- **Provider auth/quota/spend:** disable the affected provider or sensitive
  imports, rotate credentials if rejected, and inspect atomic reserved plus
  spent units before raising a budget.
- **Dead letters / claim churn:** preserve the job IDs, inspect retry traces,
  and use the provider-outage or Redis-loss runbook.

## Verification

- Unit tests cover bounded labels, histograms, sink-boundary redaction,
  authenticated metrics, and FastAPI span emission.
- A Redis integration test proves increments are atomic, visible between
  registries, and still present after registry recreation.
- In staging, restart API and worker replicas, confirm counters remain, follow
  one request trace through Celery/database/provider spans, send a synthetic
  secret field through a test logger, and fire each alert with a temporary low
  threshold.
