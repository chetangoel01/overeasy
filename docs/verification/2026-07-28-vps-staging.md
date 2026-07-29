# OVH VPS staging deployment

## Purpose and outcome

Deploy the Ladle backend to a fresh OVH Ubuntu 26.04 VPS with empty application
state, guarded public HTTPS access, key-only SSH, host firewalling, health
monitoring, and validated PostgreSQL backups.

Staging is active at:

```text
https://vps-8b0be574.vps.ovh.us
```

The active immutable release is
`f3e3bb25df07be55214bb721d857614b2b4f0937`. The deployment state reports
`STATUS=active` and `PHASE=complete`.

## Host and access

- Host: `vps-8b0be574.vps.ovh.us`
- OS: Ubuntu 26.04
- IPv4: `135.148.42.60`
- IPv6: `2604:2dc0:121::64f/128`
- IPv6 gateway: `2604:2dc0:121::1`
- SSH host key:
  `SHA256:u7Gmvsdr7fCoZt3yQpZb3udIkbyA3FIorYLwSZQoCQA`
- Dedicated local identity: `~/.ssh/ladle-ovh-staging`
- A fresh key-only SSH login succeeded after hardening.
- Password SSH and root SSH login were rejected after hardening.
- The effective daemon policy is public-key-only with root login disabled.
- KVM remained available as the recovery console throughout provisioning and
  hardening.

The installed image requested DHCPv6 and router advertisements but received
neither an assigned address nor a default route. The OVH-assigned `/128` and
gateway were confirmed in the control panel, tested non-persistently, then
installed through `/etc/netplan/51-ladle-ipv6.yaml`. Public IPv6 connectivity
and TLS subsequently passed.

## Firewall and exposed services

The repository provisioner installed Docker and persistent IPv4/IPv6 firewall
rules. Both host input policies default to drop. Public listeners are limited
to:

- TCP `22` for SSH
- TCP `80` and `443` for Caddy
- UDP `443` for HTTP/3

PostgreSQL, Redis, MinIO, the API, and Nginx have no host-published ports.

## DNS and TLS

`ladle.app` was still parked on `ns1.dan.com` and `ns2.dan.com`;
`api.ladle.app` resolved to parking addresses rather than the VPS. No DNS
mutation was attempted. Guarded staging therefore uses the existing OVH
hostname, whose A and AAAA records resolve to this VPS.

TLS validation succeeded over IPv4 and IPv6. The first external verification
found that HSTS existed only on the reused Mac deployment's Nginx `8080`
listener, while the VPS routes through Nginx `8082`. Commit `f3e3bb2` moved
the HSTS responsibility to Caddy, the VPS TLS boundary. The complete external
verifier then passed:

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

Missing and incorrect staging keys return `404`. The local staging key is kept
outside the repository in a mode-`0600` file and was never printed.

## Application state and services

- `LADLE_ENVIRONMENT=development`
- Worker provider mode remains `fake`; no paid provider credential is
  installed.
- PostgreSQL and MinIO started empty.
- Alembic migrations reached revision `0012`.
- Live database counts were `users=0` and `recipes=0`.
- PostgreSQL, Redis, MinIO, API, worker egress, worker, Beat, Nginx, and Caddy
  were running; all services with health checks reported healthy.
- API, edge, Celery worker, and Beat deployment gates passed before activation.

## Operations and recovery

The Ubuntu-side installer validated the systemd units before installing them.
`ladle-health.timer` runs every five minutes and
`ladle-backup.timer` schedules nightly backups. Direct health verification
reported `health healthy`.

The latest first-deployment backup was:

```text
ladle-20260729-035600-47540.dump
SHA-256 edbb6ea66ce2be423c81335d7090a742bc2a7fabefcb788251111eda6e2fa66f
```

The digest validated. The archive restored successfully into a disposable,
network-isolated PostgreSQL 16 container. The restored database reported
schema `0012`, zero users, and zero recipes. The drill did not touch the live
volume, and its container was removed afterward.

## Repository verification

- The IPv6 documentation regression failed before the Netplan procedure was
  added and passed afterward.
- The public-hostname forwarding regression failed before `push.sh` accepted
  and forwarded a validated first-deployment hostname and passed afterward.
- The HSTS boundary regression failed before the Caddy header was added and
  passed afterward.
- All 127 VPS profile tests passed.
- `push.sh` passed both `sh -n` and `dash -n`.
- Ruff passed for the changed deployment test.
- `git diff --check` passed before each deployment commit.

## Remaining staging and production work

- Gain DNS control of the intended application domain, create verified A/AAAA
  records, and perform a planned hostname/environment rotation.
- Install the live extraction provider credential through the allowlisted
  standard-input setter before running paid YouTube/TikTok/Instagram journeys.
- Add a passphrase to the dedicated local SSH identity before production.
- Complete real-device guest bootstrap, refresh, import, thumbnail, sync, and
  account-deletion journeys.
- Keep the staging access gate until production App Attest, Apple/Google
  identity, tracing, externally durable object storage, off-provider database
  backups, and TLS-credentialed managed PostgreSQL/Redis are ready.

No password, private key, staging key, provider token, environment-file
contents, signed URL, or provider response body is recorded here.
