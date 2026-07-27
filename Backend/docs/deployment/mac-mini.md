# Mac mini private staging

## Purpose

This profile runs the Ladle API, one Celery worker, Beat, PostgreSQL, and Redis
on the always-on Mac mini through Docker Desktop. It is the low-cost private
staging environment for device testing and a small invited beta. It is not the
public production deployment.

## User-visible behavior

- A rootless Nginx edge listens only on host loopback ports `4112` (PROXY
  protocol v2), `4113` (local operations), and `4114` (HTTPS-terminated
  development tunnels). The API has no published port.
- The edge image contains its read-only configuration; it does not require an
  unattended host file-sharing mount.
- A dedicated host-publish network lets Docker Desktop bind those loopback
  ports while the API remains isolated on its internal edge network.
- Tailscale Serve terminates HTTPS for tailnet devices and forwards PROXY
  protocol v2 so per-IP abuse controls receive the original tailnet address.
- The tailnet ingress adds the two-year HSTS policy expected by the external
  security verifier; the local operations listener does not.
- The tailnet edge hides OpenAPI, interactive docs, ReDoc, and metrics; those
  routes are never exposed to tailnet clients by the staging configuration.
- The optional development-tunnel edge also hides those routes, forwards the
  original ngrok client address, marks the upstream request as HTTPS, and
  removes the device tunnel key before the request reaches the API.
- Nginx rejects bodies over 1 MiB with the typed `invalidRequest` response
  before FastAPI allocates or parses them.
- Imports use the configured live text/extraction providers.
- Audio transcription, frame sampling, and server media fallback are disabled.
- Object storage and private thumbnail copies are disabled. Imports retain
  provider-hosted HTTPS thumbnails as remote recipe images instead.
- The Mac-only image omits FFmpeg and its media libraries.
- PostgreSQL and Redis are never published to the LAN or internet.
- User LaunchAgents run a five-minute local health/disk watchdog and a
  validated PostgreSQL backup every night at 03:15.

## Important decisions

- The base Compose file remains the source of service definitions and volumes.
  The Mac mini profile only adds restart policies, bounded logs, resource
  limits, staging secrets, rate limiting, durable metrics, ingress/egress
  enforcement, and non-media flags.
- The Compose project stays named `backend`, so upgrading the older Mac mini
  installation preserves its PostgreSQL and Redis `backend_ladle-*` volumes.
- MinIO is profile-disabled because both named-volume and host-bind trials
  repeatedly tripped its 30-second drive probe under OrbStack. The empty old
  volume and empty host directory remain untouched for rollback evidence.
- `deploy.sh` creates missing staging secrets in ignored `.env.mac-mini` with
  mode `0600`. Provider credentials can be copied into that file before the
  first deployment.
- This environment intentionally remains `development`. App Attest and all
  public-production fail-closed requirements must be enabled before a general
  public deployment.
- Tailscale remains the persistent ingress. Port `4114` may be attached to a
  temporary ngrok agent for Personal Team device testing only when ngrok
  rejects requests without a freshly generated `X-Ladle-Tunnel-Key`. Keep the
  port loopback-only, stop the endpoint after testing, and never add router
  port forwarding or use Tailscale Funnel for this profile.
- The worker shares the network namespace of a minimal firewall sidecar. Rules
  apply only to UID 10001: Docker DNS, the resolved PostgreSQL/Redis endpoints,
  and public TCP/443 are allowed; private, loopback, link-local, metadata,
  multicast, reserved, non-HTTPS, and all IPv6 egress are rejected. Only the
  sidecar has `NET_ADMIN`; the worker remains capability-free.
- The production worker removes the base profile's `.eval-cache` bind mount.
  Evaluation artifacts are development-only, and removing the host write path
  also avoids runtime file-sharing prompts on unattended Docker Desktop hosts.

## Deploy or upgrade

From `Backend/` on the Mac mini:

```bash
LADLE_MAC_MINI_DOCKER_CONTEXT=desktop-linux ./deploy/mac-mini/deploy.sh
```

The deploy script validates the merged Compose configuration, starts the data
services, stops the unused MinIO service, builds the runtime, runs Alembic
before replacing API/worker processes, waits for the egress gateway and local
edge readiness, and configures Tailscale's TLS-terminated PROXY protocol v2
forwarder. It first replaces any legacy web proxy on this node so repeated
deployments converge on the single hardened route.

`LADLE_MAC_MINI_DOCKER_CONTEXT` is optional. Set it when more than one Docker
runtime is installed so deployment cannot silently target the wrong daemon.

Install the user login agent once so Docker Desktop starts after a Mac reboot:

```bash
./deploy/mac-mini/install-autostart.sh
```

Compose's `unless-stopped` policies then restore the database, Redis, API,
worker, Beat, egress gateway, and edge without rebuilding or rerunning the
deploy script. Tailscale retains its Serve route independently.

Install the local operations agents once:

```bash
./deploy/mac-mini/install-local-operations.sh
"$HOME/Library/Application Support/Ladle/local-operations.sh" backup
```

The health agent checks local readiness, all seven runtime containers, and the
20 GiB free-disk floor every five minutes. The backup agent creates a
custom-format PostgreSQL archive at 03:15, validates its table of contents with
`pg_restore`, writes a SHA-256 sidecar, and removes matching archives older
than 35 days. macOS notifications fire only on the first successful backup,
failure transitions, and recovery.

State, configuration, logs, and archives live outside the checkout:

- `~/Library/Application Support/Ladle/{health,backup}.state`
- `~/.config/ladle/local-operations.env`
- `~/Library/Logs/Ladle/local-operations.log`
- `~/Backups/ladle/ladle-*.dump`

For a temporary Personal Team device tunnel, install and authenticate the
ngrok agent at `~/bin/ngrok`, then run:

```bash
./deploy/mac-mini/ngrok.sh start
./deploy/mac-mini/ngrok.sh status
./deploy/mac-mini/ngrok.sh stop
```

The launcher generates the device key and Traffic Policy in
`~/.config/ladle/ngrok` with owner-only permissions and logs the agent at
`~/Library/Logs/Ladle/ngrok.log`. It prints only the public HTTPS URL; use
`key-file` to locate the key for a device build without printing it.

The empty configuration file accepts shell assignments for the documented
`LADLE_*` overrides in `local-operations.sh`, including retention and disk
thresholds. It is mode `0600`; do not place its contents in source control.
These local archives protect against container or database mistakes, but not
loss of the Mac or its disk. They are intentionally not represented as
off-machine or point-in-time-recovery backups.

To roll back to a commit before the edge was introduced, deploy that commit and
restore the earlier plain HTTP forwarder with
`Tailscale serve --bg --yes 4112`. Do not leave the PROXY protocol forwarder
pointing at an API process that does not expect its header.

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

curl --fail http://127.0.0.1:4113/health/ready
curl --fail http://127.0.0.1:4114/health/ready
./deploy/mac-mini/ngrok.sh status
/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status
launchctl print "gui/$(id -u)/com.ladle.health-watch"
launchctl print "gui/$(id -u)/com.ladle.database-backup"
tail -n 20 "$HOME/Library/Logs/Ladle/local-operations.log"
```

Keep at least 20 GB free, retain off-machine database backups, and check the
worker/API logs before updating. The profile rotates container logs at three
10 MB files per service.

## Verification

- `uv run pytest -q tests/unit/deploy/test_mac_mini_profile.py`
- `docker compose ... config`
- Alembic migration exit status
- Local `/health/ready`
- Development-tunnel `/health/ready`, with ngrok rejecting a missing or wrong
  device key before the request reaches the host
- Tailnet HTTPS `/health/ready`
- A 1 MiB-plus local and tailnet request returns `413` plus
  `error.code=invalidRequest`
- Nginx access logs show the real tailnet source address supplied through
  PROXY protocol v2
- Worker probes can reach PostgreSQL, Redis, and a public HTTPS endpoint, while
  cloud metadata, localhost, RFC1918, and public non-443 destinations are
  rejected with matching firewall counters

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

## Deployment update: 2026-07-27

- Current deployed commit: `c876fa6`
- Runtime: Docker Desktop `desktop-linux`; the unresponsive OrbStack runtime
  was stopped but its data image was not reset or deleted.
- Restored data: the verified pre-edge dump
  `/Users/chetangoel/Backups/ladle/ladle-20260727-000040-pre-edge.dump`
  restored to the new Docker Desktop volumes. Its mode is `0600`, its SHA-256
  is `b8f03b8194ef811e228c3408c45caa12712e781edb2d4a8d36147fe6b325c9b0`,
  `pg_restore --list` passed, revision is `0011`, and the two original users
  remain.
- Fresh recovery point:
  `/Users/chetangoel/Backups/ladle/ladle-20260727-004808-post-edge.dump`
  exists on both the Mac mini and operator workstation with mode `0600` and
  matching SHA-256
  `80b6127c5c4c965d23b317fce6116037d9642f5f9d3d51c9ed29132178572157`.
  It restored into an empty PostgreSQL 16 container at revision `0011` with
  two users and two recipes.
- Startup: `com.ladle.docker-start` is installed in the user's LaunchAgents
  and launch-tested. Docker restart then restored all seven containers from
  their `unless-stopped` policies in about ten seconds without a deploy.
- Ingress: local and tailnet readiness passed; raw HTTP cannot use the PROXY
  listener; a real tailnet request logged the original `100.x` client address.
  Local and tailnet bodies over 1 MiB returned typed `413 invalidRequest`.
- External boundary: `verify_staging.py` passed TLS, HSTS/security headers,
  secret-leak checks, dependencies, hidden diagnostics, authentication, and
  the request-size boundary.
- Rate limiting: a local-only guest probe returned typed `429 rateLimited`
  with `Retry-After` on attempt six. Its one temporary account was deleted and
  the database user count remained two.
- Worker egress: live probes allowed only PostgreSQL, Redis, and public HTTPS;
  cloud metadata over HTTP/HTTPS, private and loopback addresses, public
  non-HTTPS, IPv4-mapped metadata, and IPv6 were rejected with firewall
  counters.
- Hardening: API, worker, gateway, and edge are read-only and mount-free with
  no-new-privileges. Only the gateway has `NET_ADMIN`; the worker shares its
  exact network namespace. Only edge ports `4112` and `4113` bind host
  loopback.
- Rollback: commit `22de9e9` deployed successfully against the current
  database, stayed ready at `0011` with two users, and exposed the expected
  older OpenAPI behavior. Rolling forward through the normal deployment gate
  restored commit `c876fa6`, retained the same data, and returned tailnet
  OpenAPI access to `404`.
- Video processing remains disabled. Supadata and SoScripted were not called.
- The current OpenRouter, Supadata, and SoScripted credentials must be rotated
  before broader use because their values appeared in operator terminal
  output during an earlier configuration diagnostic.

The non-attested external checks pass, but
`LADLE_ENVIRONMENT=development` intentionally leaves real App Attest
enforcement off. Do not expose this endpoint outside the tailnet. The host
reported about 31 GiB free on 2026-07-27 after operator cleanup, above the
20 GiB operating target. The old OrbStack data remains preserved for recovery.

## Deployment update: 2026-07-27 thumbnail retention

- Detached deployment commit `13ac0b6` contains the thumbnail-retention and
  bounded recipe-inference backend changes from branch commit `5f3dd6e`.
- The normal deployment gate upgraded the database from revision `0011` to
  `0012`. Local and keyed ngrok readiness passed, and the worker remained
  healthy.
- A real Instagram import submitted through the keyed ngrok route completed
  as `needsReview`. Fetching its recipe returned one HTTPS provider thumbnail,
  proving the no-object-storage path from acquisition through recipe output.
  Account deletion returned `204`, removing the temporary smoke-test guest.
