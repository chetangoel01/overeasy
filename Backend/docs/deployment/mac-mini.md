# Mac mini private staging

## Purpose

This profile runs the Ladle API, one Celery worker, Beat, PostgreSQL, and Redis
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
- Initial verified commit: `46d1922`
- Current deployed commit: `e9e07c7`
- Private endpoint:
  `https://chetans-mac-mini.tail19e758.ts.net`
- Pre-migration database backup:
  `/Users/chetangoel/Backups/ladle/ladle-20260726-214838.dump`
- Post-verification backup copied to the operator workstation:
  `/Users/chetangoel/Backups/ladle/ladle-mac-mini-20260726-post-head.dump`;
  `pg_restore --list` passed and its SHA-256 is
  `29e3ac33512c5bdf9d62a91b6b5a47f8e36f49c6eea35ee7f04d4a4f789cd169`
- Migration: upgraded transactionally from `0003` through `0011 (head)`
- Readiness: database, broker, result backend, worker, Redis-backed metrics,
  Redis-backed rate limiting, and configuration ready
- Text-only live smoke: guest creation `201`, import submission `202`,
  OpenRouter extraction `200`, terminal job `ready`, recipe retrieval `200`
  for both Garlic Butter Toast and the post-upgrade Simple Tomato Toast check,
  with four ingredients and three steps; account deletion returned `204` and
  both test accounts and recipes were removed
- Runtime: live extraction provider, no FFmpeg, audio transcription off, frame
  analysis off, server media fallback off
- Object storage: disabled after the prior named volume was verified to contain
  zero current objects, versions, or delete markers; both attempted storage
  locations were retained
- Ingress: Tailscale Serve only; PostgreSQL and Redis have no published ports,
  while the API binds host loopback only
- Container policy: API, worker, and Beat have read-only roots, bounded tmpfs,
  all capabilities dropped, no-new-privileges, Docker's built-in seccomp
  profile, and CPU/memory/PID/file limits; every service uses
  `unless-stopped` and three 10 MB JSON log files
- Worker replacement drill: an idle worker was force-recreated, received a new
  container identity, reached healthy, and answered Celery ping
- Redis restart drill: AOF and RDB status were healthy before restart, a
  short-lived database-15 canary survived the restart, the worker reconnected,
  and every API readiness check returned ready afterward
- Cleanup: ten untagged Ladle build images, one obsolete stopped Ladle
  migration container/image, and the reproducible BuildKit cache were removed.
  No Immich, media-stack, user-data, or named-volume content was deleted.

The public-production verifier intentionally does not pass this private profile:
`LADLE_ENVIRONMENT=development` omits HSTS and public App Attest enforcement.
Do not expose this endpoint outside the tailnet. The host still reports about
13 GiB free after the scoped container cleanup, below the 20 GiB operating
target. Free or add at least 7 GiB before retaining meaningful user data; the
remaining large consumers are host-level Xcode simulators/caches and personal
data, which this deployment did not delete.
