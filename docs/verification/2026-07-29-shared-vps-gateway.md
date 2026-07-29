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

Pending the verified live cutover. No password, private key, staging key,
environment-file content, opaque gateway generation, signed URL, or provider
response body belongs in this record.
