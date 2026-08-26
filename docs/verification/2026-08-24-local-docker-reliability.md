# Local Docker Reliability

**Original capability:** August 24, 2026

**Consolidated:** August 26, 2026

## Purpose

Keep the local backend dependable after a media-heavy Celery worker exhausted
its former 1 GiB container limit and remained stopped, which made API
readiness fail and blocked imports.

## Behavior

- Local Compose processes one import at a time by default.
- The worker has a configurable 2 GiB memory ceiling and two-CPU allowance.
- The API, worker, and Beat restart after unexpected exits.
- One-shot migration and object-storage initialization retain their completion
  behavior.
- Resource defaults can be overridden through `Backend/.env` without
  weakening the checked-in defaults.
- Existing PostgreSQL, Redis, and MinIO volumes are unaffected.

## Historical production evidence

The source branch recorded a clean rebuild, successful migrations and
readiness, a deterministic guest-to-ready import and sync journey, and a live
Instagram import that completed in 34 seconds without retrying or
destabilizing the worker. This record preserves that evidence without claiming
that paid-provider traffic was repeated during consolidation.

## Consolidation verification

- The Compose-policy regression test failed first because the three
  long-running services lacked restart policies.
- The focused regression passed: 1 test.
- The complete deployment test directory passed: 47 tests.
- Backend Ruff passed.
- `docker compose config --quiet` accepted the resolved configuration.
- Documentation now uses host port 4112 consistently and preserves the
  physical-device boundary: loopback is for the Mac and simulator; a device
  uses the guarded release endpoint or opt-in tunnel.
