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
- `/ops` serves an operator dashboard rendered from the same counters. It
  carries its own credential, `LADLE_OPS_DASHBOARD_TOKEN`, which production
  refuses to start without and refuses to let equal the metrics token: a
  browser holds the dashboard one in a cookie, and the Prometheus token must
  never reach a browser. The token arrives once as `?token=`, moves into an
  HttpOnly, `SameSite=Strict`, `/ops`-scoped cookie that expires after twelve
  hours, and is absent from every later URL. The cookie is marked `Secure`
  whenever the request arrived over HTTPS, which is the scheme Caddy forwards,
  rather than when the environment is production: the VPS runs the documented
  `LADLE_ENVIRONMENT=development` exception behind a real gateway. Everything
  without that cookie answers 404, matching `/metrics`.
- Because that one handoff puts a credential in a request target, the access
  log is not allowed to keep it. The production Compose command passes
  `--no-access-log`, and importing the ASGI application installs a filter that
  strips query strings from `uvicorn.access` records regardless of how the
  server was started — the Compose command runs uvicorn directly, so
  `ladle/api/__main__.py` never executes there. The shared Caddy gateway
  declares no `log` directive, so it records no request targets at all.
- The dashboard polls `/ops/metrics.json` every five seconds and computes rates
  from counter deltas in the browser, so request-per-minute charts build up
  while the page is open and totals read "since the counters were last reset."
  Readiness is a separate, slower `/ops/readiness.json` on a sixty-second
  timer, because a readiness check contacts every dependency and wakes a Celery
  CLI process; it must never run at the polling cadence.
- HTTP and import latency use Prometheus histograms. Metrics cover import
  outcomes, cache disposition, provider outcomes/cost, worker retries, sync
  conflicts/resets, rate-limit rejection policy, queue health, stuck jobs,
  dead letters, claim churn, and cleanup failures.
- Celery's ready and periodic heartbeat signals update the durable
  worker-liveness gauge even when no imports are running. Beat liveness advances
  only when its scheduled maintenance task is received, so the two absence
  alerts remain independent. Both alert expressions also use Prometheus
  `absent(...)`, covering a process that never emitted its first heartbeat.
- Every API and Celery worker log line is JSON. The worker installs the same
  formatter through Celery's production logging signal instead of accepting
  Celery's default plain-text root logger. The formatter—not individual
  callers—redacts sensitive keys, `SecretStr` values, bearer credentials, and
  private import fields. Authenticated API completion logs carry a keyed,
  environment-specific 16-hex user pseudonym rather than a user UUID. Request
  ID, job ID, orchestration/acquisition/extraction/thumbnail stage,
  provider/retry context, duration, and terminal result are structured fields.
- OpenTelemetry emits W3C trace context through FastAPI, Celery, Redis,
  SQLAlchemy, outbound provider calls, and the worker. Provider calls are
  traced by patching the HTTP library: `httpx` for the clients this codebase
  builds itself (OpenRouter, USDA, acquisition, audio, search) and `httpx2`
  for the anthropic 1.x SDK, which moved off `httpx` in 1.x and is invisible
  to the `httpx` instrumentor on its own. The SDK's migration guide offers
  `httpx2.alias_httpx()` instead; that rebinds `import httpx` process-wide
  for every direct caller, so both packages are instrumented separately and
  a unit test drives the real SDK client through the extraction call site to
  keep it that way. The production OTLP endpoint must use HTTPS.

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

The single-VPS deployment runs none of steps 3-5: it has no collector,
Prometheus, or Grafana, and its assigned hostname has no spare subdomain to
terminate their TLS on. `/ops` is what an operator reads there, and those
files stay in the repository for the day the deployment outgrows one host.

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
  authenticated metrics, FastAPI span emission, the required alert set,
  never-seen worker/Beat detection, and dashboard coverage.
- API tests cover the `/ops` credential: hidden without it, hidden when the
  cookie carries the metrics token instead, a query token that becomes a
  cookie, a fast poll that wakes no probe, and the relaxed `/ops` content
  security policy that leaves every other route's policy alone.
- A Redis integration test proves increments are atomic, visible between
  registries, and still present after registry recreation.
- In staging, restart API and worker replicas, confirm counters remain, follow
  one request trace through Celery/database/provider spans, send a synthetic
  secret field through a test logger, and fire each alert with a temporary low
  threshold.
