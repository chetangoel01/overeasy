# Ladle Backend

The Ladle backend is a Python 3.12 FastAPI application with Celery workers.
It is developed and locked with [uv](https://docs.astral.sh/uv/).

## Local toolchain

```bash
uv sync --all-groups
uv run pytest -q
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle
```

Copy `.env.example` to an ignored `.env` for local development. Replace the
development-only signing and encryption placeholders before setting
`LADLE_ENVIRONMENT=production`. Local Compose uses deterministic fake
providers. Live workers require the configured extraction provider credential;
Supadata and SoScripted are optional URL-transcript fallbacks.

See [`docs/integration-reference.md`](docs/integration-reference.md) for the
repository/runtime path map, complete API reference and examples, provider
fallback behavior, iOS connection setup, and PostgreSQL data dictionary.
For an interactive guest-to-import-to-recipe walkthrough, start the local stack
and use the [pipeline Swagger guide](docs/pipeline-swagger.md).

## Local stack

```bash
docker compose up -d --build
curl --fail http://127.0.0.1:4112/health/live
curl --fail http://127.0.0.1:4112/health/ready
```

Readiness checks PostgreSQL, Redis, the Celery worker, and the private
object-storage bucket. The API, worker, and Beat restart after unexpected
exits. Local imports default to one worker process, a 2 GiB worker memory
limit, and two CPUs so media-heavy jobs do not overlap inside a smaller shared
ceiling. Override `LADLE_WORKER_CONCURRENCY`, `LADLE_WORKER_MEMORY_LIMIT`, or
`LADLE_WORKER_CPU_LIMIT` in `.env` only when Docker Desktop has enough
capacity.

Prometheus-format bounded-label counters are available at `/metrics`. Run
`scripts/check_secrets.sh` before publishing a deployment artifact.

For the private Mac mini staging deployment, see
[`docs/deployment/mac-mini.md`](docs/deployment/mac-mini.md).
For the right-sized single-host production deployment, including OAuth,
backups, shared Caddy routing, and rollback, see
[`docs/deployment/vps.md`](docs/deployment/vps.md).

Apple and Google sign-in remain disabled in local development until their
provider settings are supplied. Production refuses to start without both
shipped identity providers. Apple uses a read-only mounted private-key file
plus its team ID, key ID, and `com.ladle.ios` bundle ID; Google requires its
server OAuth client ID. Provider credentials and optional browser cookies
belong only in host-managed secrets, never in the repository or iOS
application.

## Guarded physical-device builds

The Debug `.localhost` route belongs to the Mac and simulator. Before building
for a physical iPhone against local Docker, rotate a per-build key and start
the guarded HTTPS tunnel:

```bash
./scripts/device_tunnel.sh rotate
xcodebuild build \
  -project ../Ladle.xcodeproj \
  -scheme Ladle \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -xcconfig ../.private/DeviceTunnel.xcconfig \
  -allowProvisioningUpdates
```

`rotate` invalidates older tunnel builds, writes a mode-`600` ignored
xcconfig, and verifies that missing or incorrect keys receive `404`,
authorized readiness receives `200`, and `/metrics` remains hidden. Use
`start` to keep serving an already installed build without rotating its key.
Use `stop` when device testing ends; it closes the public endpoint and restores
local simulator thumbnail URLs.

The tunnel listener is published only on host loopback port `4114`. API
requests require the embedded `X-Ladle-Tunnel-Key`; signed private-thumbnail
paths are exempt because native image loading cannot attach that header, while
MinIO still validates the short-lived object signature.
