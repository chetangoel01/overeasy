# Local Docker reliability

Date: August 24, 2026

## Purpose

Keep the local backend dependable for app development after the live Celery
worker exhausted its 1 GiB container limit and remained stopped, leaving API
readiness unavailable and blocking imports.

## Behavior and decisions

- Local Compose processes one import at a time by default so media acquisition
  and transcription jobs cannot overlap their peak memory use.
- The worker has a configurable 2 GiB memory ceiling and two-CPU allowance.
- The API, worker, and Beat restart after unexpected exits. One-shot migration
  and object-storage initialization services retain their completion behavior.
- The resource defaults can be overridden through `Backend/.env` without
  weakening the checked-in defaults.
- Existing PostgreSQL, Redis, and MinIO volumes are preserved.

## Affected components

- `Backend/docker-compose.yml`
- `Backend/.env.example`
- `Backend/README.md`
- `Backend/docs/integration-reference.md`
- `Backend/tests/unit/deploy/test_container_hardening.py`

## Verification

- The new Compose-policy regression failed before the configuration change and
  passed afterward.
- `docker compose config --quiet` accepted the effective configuration.
- A clean image rebuild and migration completed successfully.
- `/health/ready` reported the broker, Celery result backend, configuration,
  PostgreSQL, metrics Redis, object storage, and worker as ready.
- An authenticated Discover request returned five results.
- A deterministic full-stack journey created a guest, submitted an import,
  dispatched it through Redis and Celery, persisted a ready recipe, fetched the
  recipe, observed it through incremental sync, and loaded Discover.
- The stack was restored to the private `.env` live-provider mode after the
  deterministic test.
- In restored live mode, an Instagram import completed media acquisition,
  transcription, structured extraction, and recipe persistence as `ready` in
  34 seconds without retrying or destabilizing the worker.
- The Debug routing reference now states the correct host port and preserves
  the physical-device boundary: `.localhost` is for the Mac and simulator;
  device builds use the guarded VPS or tunnel.
