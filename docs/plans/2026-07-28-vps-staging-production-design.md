# VPS Staging-to-Production Deployment Design

## Status

Approved for implementation on `codex/vps-staging-deployment`.

This design moves the Overeasy backend from the private Mac mini staging host
to a new OVHcloud VPS. Staging starts with empty PostgreSQL and object-storage
state. The same server can become the first production host after it passes the
documented promotion gates.

## Purpose

The Mac mini deployment depends on a home host, Docker Desktop, local disk,
Tailscale, and temporary ngrok routing. Those layers have caused container
startup stalls and intermittent device access.

The VPS deployment provides:

- an always-on Linux host with a stable public IPv4 and IPv6 address;
- direct HTTPS at `api.ladle.app`;
- a repeatable, repository-owned deployment procedure;
- staging access from signed test builds without a VPN;
- validated database backups and deterministic recovery;
- a bounded path from private staging to public production.

The iOS app, Share Extension, Xcode builds, code signing, and App Store upload
remain on the developer Mac.

## Selected host

- Provider: OVHcloud US
- Plan: VPS-2
- Operating system: Ubuntu 26.04 LTS
- Capacity: 4 vCores, 8 GB RAM, 75 GB NVMe
- Hostname: `vps-8b0be574.vps.ovh.us`
- IPv4: `135.148.42.60`
- IPv6: `2604:2dc0:121::64f`
- Initial account: `ubuntu`

Docker Engine officially supports Ubuntu 26.04. Provisioning uses Docker's
signed APT repository rather than Ubuntu's alternate Docker package or the
convenience installation script.

## Considered approaches

### Selected: dedicated VPS deployment profile

Add a Linux-specific Compose override, public TLS edge, provisioning script,
deployment gate, health watchdog, and backup job while reusing the existing
application images and internal service topology.

This keeps infrastructure inexpensive and makes each host mutation
reproducible. It also preserves the current container hardening and provides a
clear upgrade path.

### Rejected: minimally adapt the Mac mini profile

The quickest route would install Docker and manually run the existing Compose
files. That would carry Mac-specific Tailscale, ngrok, LaunchAgent, filesystem,
and Docker Desktop assumptions onto Linux. TLS, firewalling, backup retention,
and repeatable recovery would remain operator memory instead of release gates.

### Deferred: split into managed data services

Managed PostgreSQL, Redis, and object storage would reduce single-host risk but
would multiply the initial monthly cost and operational surfaces. The first
VPS deployment keeps state on one server and documents managed services as the
next reliability step when beta traffic or recovery requirements justify it.

## Architecture

```text
iOS app and Share Extension
             |
             | HTTPS + bearer auth
             | staging: X-Ladle-Tunnel-Key
             v
       Caddy public edge
       ports 80 and 443
             |
             v
       hardened Nginx edge --------------> private MinIO thumbnails
             |
             v
         FastAPI API
             |
        +----+-------------------+
        |                        |
        v                        v
   PostgreSQL                Redis
                                 |
                                 v
                         Celery worker + Beat
                                 |
                                 v
                    acquisition/extraction providers
```

Caddy owns public certificate issuance and renewal. The existing hardened
Nginx behavior remains the application edge: request-size enforcement, hidden
diagnostic routes, forwarded-address policy, and signed private-thumbnail
proxying. API, PostgreSQL, Redis, MinIO, worker, and Beat expose no host ports.

Only SSH, HTTP, and HTTPS are reachable from the internet. Docker-published
traffic is restricted in the `DOCKER-USER` chain because ordinary UFW rules do
not govern published container ports reliably.

## Staging access

Staging uses `api.ladle.app` so the Release client exercises its eventual
production hostname and TLS boundary. A random `X-Ladle-Tunnel-Key` is embedded
only in designated staging builds and rejected at the edge when absent or
incorrect.

Signed MinIO thumbnail paths do not carry the app-only header. They remain
reachable only with a valid short-lived object signature. OpenAPI, ReDoc, and
metrics stay hidden from the public edge.

The staging database and bucket start empty. No users, recipes, imports,
provider cache entries, or thumbnails are copied from the Mac mini.

## Host access and secret handling

The OVH one-time password is retrieved by the owner and used locally only to
install a dedicated Ed25519 public key. It is never pasted into chat, committed,
or stored in deployment files.

After key access is verified:

- root SSH login is disabled;
- SSH password authentication is disabled;
- the `ubuntu` account retains controlled `sudo` access;
- deployment secrets live in one root-readable environment file outside the
  checkout;
- generated signing, encryption, object-storage, metrics, and staging-access
  secrets are never printed;
- provider credentials are copied through a non-echoing local path;
- credentials previously exposed in operator output are rotated before public
  production.

## Deployment and updates

Provisioning is idempotent and limited to host prerequisites: OS updates,
Docker's official repository, Docker Engine and Compose, firewall rules,
directories, and systemd units.

Application deployment:

1. validates configuration and required secrets;
2. pulls or builds the exact repository revision;
3. starts PostgreSQL, Redis, and MinIO;
4. initializes the private versioned bucket and lifecycle;
5. runs Alembic as a one-shot migration;
6. replaces API, worker, Beat, and edge services;
7. waits for local readiness and worker health;
8. verifies the public staging boundary.

A failed migration or readiness check stops the rollout and retains the prior
runtime where possible. Task-sized commits provide the deployment rollback
revision; database backups provide the state rollback boundary.

## Backups and recovery

The host creates a PostgreSQL custom-format dump nightly. Each dump is:

- written through a temporary file;
- checked with `pg_restore --list`;
- accompanied by a SHA-256 digest;
- permissioned for the deployment operator only;
- retained locally for 35 days.

OVH's daily VPS backup is a second whole-machine recovery path, not a
substitute for a database-aware dump. Before production, validated dumps must
also be copied to storage outside the VPS and a restore into an empty
PostgreSQL 16 instance must pass.

MinIO data is included in machine recovery during staging. Before production,
thumbnail state must have either an off-host copy or a migration to externally
durable S3-compatible storage that supports the required versioning and
lifecycle APIs.

## Monitoring and failure behavior

A systemd timer checks:

- the public and local readiness endpoints;
- expected container count and health;
- Celery worker response and Beat heartbeat;
- PostgreSQL backup freshness and validation;
- free disk against a 20 GiB floor;
- certificate expiry;
- Docker service state.

Failures are recorded in bounded journal/container logs and produce a
transition alert once an external notification destination is configured.
Containers use `unless-stopped` restart policies, bounded logs, read-only roots
where applicable, dropped capabilities, PID/file limits, and explicit CPU and
memory ceilings.

Third-party source acquisition remains independent of host availability.
Datacenter-IP blocking, social-platform changes, or provider outages continue
to use the existing acquisition fallback, retry, circuit-breaker, and terminal
failure behavior.

## Production promotion

The server remains staging until all of the following pass:

- multi-day host, restart, import, sync, thumbnail, and backup soak;
- a real off-host database restore drill;
- production Apple, Google, App Attest, provider, signing, encryption, tracing,
  metrics, rate-limit, and object-storage configuration;
- rotation of credentials previously exposed in terminal output;
- physical-device guest, sign-in, import, share, sync, and deletion journeys;
- public TLS, security-header, hidden-diagnostic, request-size, rate-limit,
  worker-egress, and secret-leak verification;
- a documented rollback to the last known-good application revision.

Promotion removes the staging tunnel-key requirement only after production App
Attest and identity enforcement are live. It does not represent the single VPS
as multi-AZ: the managed PostgreSQL, cross-region backup, and seven-day PITR
requirements remain a later production-reliability milestone.

## Affected components

- `Backend/deploy/vps/`: provisioning, Compose override, edge, deployment,
  backup, watchdog, and systemd definitions
- `Backend/tests/unit/deploy/`: VPS profile and script contract tests
- `Backend/docs/deployment/`: VPS operator and promotion runbook
- `Config/Release.xcconfig` and build-time private configuration only if the
  staging endpoint or access key wiring needs adjustment
- `docs/verification/`: first deployment, restore, soak, and promotion evidence

## Verification

- Add failing deployment-contract tests before every production script or
  configuration behavior.
- Run focused VPS profile/script tests through red-green-refactor.
- Run Ruff formatting/checks, strict mypy, and the complete backend suite.
- Validate merged Compose configuration without interpolated secrets.
- Run `shellcheck` or the available shell syntax checks for every script.
- Run `git diff --check` before each commit.
- On the VPS, verify firewall exposure, container hardening, migration,
  readiness, worker, Beat, bucket policy, backup validation, and restart
  recovery.
- From outside the VPS, verify TLS, staging-key rejection, signed thumbnails,
  hidden diagnostics, request-size handling, and a live import.
- Record commands, outcomes, revision, and recovery artifacts in a companion
  verification document.
