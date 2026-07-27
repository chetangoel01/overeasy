# Mac mini private staging

## Purpose

This profile runs the Ladle API, one Celery worker, Beat, PostgreSQL, Redis,
on the always-on Mac mini through OrbStack. It is the low-cost private staging
environment for device testing and a small invited beta. It is not the public
production deployment.

## User-visible behavior

- The API listens only on the host loopback address at port `4112`.
- Tailscale Serve provides the HTTPS endpoint to devices in the same tailnet.
- Imports use the configured live text/extraction providers.
- Audio transcription, frame sampling, and server media fallback are disabled.
- Object storage and server-managed thumbnails are disabled.
- The Mac-only image omits FFmpeg and its media libraries.
- PostgreSQL and Redis are never published to the LAN or internet.

## Important decisions

- The base Compose file remains the source of service definitions and volumes.
  The Mac mini profile only adds restart policies, bounded logs, resource
  limits, staging secrets, rate limiting, durable metrics, and non-media flags.
- The Compose project stays named `backend`, so upgrading the older Mac mini
  installation preserves its PostgreSQL and Redis `backend_ladle-*` volumes.
- MinIO is profile-disabled because both named-volume and host-bind trials
  repeatedly tripped its 30-second drive probe under OrbStack. The empty old
  volume and empty host directory remain untouched for rollback evidence.
- `deploy.sh` creates missing staging secrets in ignored `.env.mac-mini` with
  mode `0600`. Provider credentials can be copied into that file before the
  first deployment.
- This environment intentionally remains `development`. App Attest and all
  public-production fail-closed requirements must be enabled before exposing
  the API outside the tailnet.
- Tailscale is the only ingress. Do not add router port forwarding and do not
  use Tailscale Funnel for this profile.

## Deploy or upgrade

From `Backend/` on the Mac mini:

```bash
./deploy/mac-mini/deploy.sh
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --yes 4112
```

The deploy script validates the merged Compose configuration, starts the data
services, stops the unused MinIO service, builds the runtime, runs Alembic
before replacing API/worker processes, and waits for readiness.

Before a migration upgrade, keep a local database backup outside the checkout:

```bash
mkdir -p "$HOME/Backups/ladle"
docker exec backend-postgres-1 pg_dump -Fc -U ladle ladle \
  >"$HOME/Backups/ladle/ladle-$(date +%Y%m%d-%H%M%S).dump"
```

## Operations

```bash
docker compose \
  --env-file .env.mac-mini \
  -f docker-compose.yml \
  -f deploy/mac-mini/docker-compose.yml \
  ps

curl --fail http://127.0.0.1:4112/health/ready
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
```

Keep at least 20 GB free, retain off-machine database backups, and check the
worker/API logs before updating. The profile rotates container logs at three
10 MB files per service.

## Verification

- `uv run pytest -q tests/unit/deploy/test_mac_mini_profile.py`
- `docker compose ... config`
- Alembic migration exit status
- Local `/health/ready`
- Tailnet HTTPS `/health/ready`

## Deployment record: 2026-07-26

- Host: `Chetans-Mac-mini.local`, Apple M4, 16 GB RAM
- Commit: `f819b22`
- Private endpoint:
  `https://chetans-mac-mini.tail19e758.ts.net`
- Pre-migration database backup:
  `/Users/chetangoel/Backups/ladle/ladle-20260726-214838.dump`
- Migration: upgraded transactionally from `0003` through `0011 (head)`
- Readiness: database, broker, result backend, worker, Redis-backed metrics,
  Redis-backed rate limiting, configuration, and object storage ready
- Smoke flow: guest creation `201`, authenticated sync `200`, account deletion
  `204`; the test account was removed
- Runtime: live extraction provider, no FFmpeg, audio transcription off, frame
  analysis off, server media fallback off
- Object storage: disabled after the prior named volume was verified to contain
  zero current objects, versions, or delete markers; both attempted storage
  locations were retained
- Ingress: Tailscale Serve only; PostgreSQL and Redis have no published ports,
  while MinIO and the API bind host loopback only
- Container policy: `unless-stopped`, three 10 MB JSON log files per service,
  and service CPU/memory limits

The public-production verifier intentionally does not pass this private profile:
`LADLE_ENVIRONMENT=development` omits HSTS and public App Attest enforcement.
Do not expose this endpoint outside the tailnet. The host had about 12 GiB free
after deployment, so storage cleanup or expansion remains required before
retaining meaningful user data.
