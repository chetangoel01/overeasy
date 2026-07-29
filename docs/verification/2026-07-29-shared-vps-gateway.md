# Shared VPS gateway migration

## Purpose

Move public HTTP and HTTPS ownership out of the Ladle Compose project into a
shared, app-neutral Caddy gateway. This lets the VPS host additional backends
on separate subdomains without exposing their databases, queues, object
stores, APIs, or workers.

The intended boundary is:

```text
Internet
  -> platform-gateway (TCP 80/443 and UDP 443)
  -> platform-edge network
  -> one uniquely named HTTP edge per backend
  -> that backend's private networks and services
```

Only HTTP edge containers may join `platform-edge`. Ladle uses the
`ladle-edge` alias. Future backends need their own hostname, Compose project,
route file, edge alias, secrets, volumes, health checks, resource limits, and
backup policy.

## Fixed host paths and identities

- Gateway assets: `/opt/platform/gateway`
- Gateway environment: `/etc/platform/gateway.env`
- Shared Docker network: `platform-edge`
- Compose project: `platform-gateway`
- Gateway container: `platform-gateway-gateway-1`
- Preserved rollback listener: `ladle-caddy-1`
- Cross-release authority lock:
  `/var/lib/ladle/locks/authority.lock`

The gateway environment is root-owned mode `0600`. Commands and evidence must
not print it, the Ladle environment, the staging access key, or the opaque
gateway generation.

## Operator flow

Run the gateway manager only from an exact immutable, root-owned Ladle release:

```text
/opt/ladle/releases/<FULL_REVISION>/Backend/deploy/vps/gateway/manage.sh
```

The supported actions are:

- `prepare`: validate the source release and host boundary, install gateway
  configuration atomically, create a fresh opaque generation, and validate
  Compose and Caddy without taking the public listeners.
- `activate`: verify `ladle-edge`, stop only the exact legacy listener,
  force-recreate the shared gateway, and require a healthy container running
  the prepared generation. Automatic recovery restores one verified listener
  on failure.
- `rollback`: stop the verified shared gateway and restore the preserved
  legacy listener. Recovery attempts to retain exactly one verified listener.
- `status`: take a shared authority lock and report prepared/current and
  listener health states without displaying secret or generation values.

The first upgrade from the legacy app-owned Caddy release has one prerequisite:
create and validate the exact `platform-edge` network contract and the
root-owned mode-`0600` authority lock before deploying the detached release.
The detached deploy then connects Ladle's edge to the shared network while the
orphaned legacy Caddy continues serving. Run `prepare` and `activate` from the
new exact release only after that deploy succeeds. Later gateway changes use
the manager directly and do not repeat this legacy bootstrap.

Expect a brief listener handoff during `activate`. Keep the stopped legacy
container until the migration verification window is complete:

```bash
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh prepare
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh activate
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh status
```

If post-activation TLS or application verification fails, run:

```bash
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh rollback
```

## Required verification

Capture redacted evidence for all of the following:

- exact deployed Git revision and active deployment state;
- manager status showing one current, healthy shared listener;
- legacy Caddy stopped and retained for rollback;
- only SSH and the shared gateway listening publicly on TCP 22, 80, and 443
  and UDP 443;
- valid IPv4 and IPv6 TLS for the staging hostname;
- missing and incorrect staging keys returning `404`;
- the complete external staging verifier passing with the correct key;
- HSTS and the existing security headers present;
- only `ladle-edge` from Ladle attached to `platform-edge`;
- no host port mappings for PostgreSQL, Redis, MinIO, API, workers, or Beat;
- `sudo ladle-operations health` reporting healthy;
- health and backup timers active;
- latest backup checksum valid.

## Pre-migration evidence

Read-only checks on 2026-07-29 confirmed:

- active revision
  `f3e3bb25df07be55214bb721d857614b2b4f0937`;
- `sudo ladle-operations health` reported `health healthy`;
- `ladle-caddy-1` was the only application container publishing public ports;
- public listeners were TCP 22, 80, and 443 plus UDP 443 on IPv4 and IPv6;
- `platform-edge` was absent;
- `ladle-health.timer` and `ladle-backup.timer` were active.

## Migration evidence

The live migration completed on 2026-07-29. The active immutable release is:

```text
c0af22f1a2e349013d58f98ff09609efad8b22e0
```

Deployment state reported `STATUS=active`, that exact revision, and
`PHASE=complete`.

### Listener handoff and rollback

- The first detached release was deployed only after the exact shared-network
  contract and authority lock were created and validated.
- The detached Ladle edge became healthy on `platform-edge` while the
  orphaned legacy `ladle-caddy-1` continued serving.
- Gateway `prepare` validated the installed Compose and Caddy configuration
  without taking the public ports.
- Gateway `activate` completed successfully. Final manager status reported
  `prepared=yes`, `active=yes`, a running healthy current gateway, and a
  stopped legacy listener.
- `ladle-caddy-1` remains stopped and preserved with its original
  `ladle:caddy` identity for the initial rollback window. Automatic and
  explicit recovery paths were covered by the local deployment profile; no
  live rollback was needed.

### Public and private boundaries

- The public listener set is exactly TCP 22, 80, and 443 plus UDP 443 on IPv4
  and IPv6.
- `platform-gateway-gateway-1` is the only running container with host-published
  application ports.
- PostgreSQL, Redis, MinIO, API, edge, workers, and Beat have only internal
  container ports or no ports.
- `platform-edge` contains exactly `platform-gateway:gateway` and
  `ladle:edge`. No Ladle data or worker service is attached.
- The active gateway is the `platform-gateway:gateway` service and reports
  healthy.

### TLS and request policy

- Direct IPv4 and IPv6 probes validated TLS.
- Missing staging credentials returned `404` over both address families.
- HSTS with the two-year policy was present over both address families.
- A TLS connection for the configured Ladle name with a different HTTP host
  returned `421`, enforcing the Host/SNI boundary.
- An unknown SNI value was rejected during TLS negotiation.
- The complete authorized external verifier passed:

```text
TLS
securityHeaders
secretLeakage
stagingAccess
dependencies
exposedEndpoints
authentication
requestTooLarge
```

### Operations and backups

- `sudo ladle-operations health` reported `health healthy`.
- A real `ladle-health.service` run passed inside its production systemd
  sandbox with `Result=success` and exit status zero.
- `ladle-operations status` displayed the shared gateway and Ladle application
  as separate ownership domains.
- `ladle-health.timer` and `ladle-backup.timer` are active.
- The latest backup remained
  `ladle-20260729-035600-47540.dump`; its SHA-256 sidecar validated.

### Repository verification

- Shared-gateway management, lock, activation, recovery, and operations changes
  passed their red-green regression cycles.
- The final shared-gateway deployment profile passed 279 tests.
- The final complete deployment test directory passed 316 tests.
- The exact pinned Caddy `2.11.4` configuration validated, and its adapted JSON
  set `strict_sni_host` on the imported-route TLS server.
- Gateway Compose rendering, POSIX `sh` and `dash` syntax, Ruff, whitespace,
  and secret-addition checks passed.
- Independent spec and quality reviews approved the gateway manager, Ladle
  operations integration, and Host/SNI hardening.

### Follow-ups

- Keep `ladle-caddy-1` stopped but preserved through the initial staging soak,
  then remove the legacy container and Ladle-owned Caddy volumes in a separate
  verified cleanup.
- Add future subdomains through validated route fragments and unique HTTP-edge
  aliases only; do not attach databases, queues, object stores, APIs, or
  workers to `platform-edge`.
- Before production, add independent encrypted off-host backups, production
  identity/App Attest controls, tracing, managed TLS data services, and the
  remaining readiness items in the staging record.

No password, private key, staging key, environment-file content, opaque gateway
generation, signed URL, or provider response body is recorded here.
