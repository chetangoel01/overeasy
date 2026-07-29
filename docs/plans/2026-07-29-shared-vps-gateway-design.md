# Shared VPS Gateway Design

## Purpose

Make the OVH VPS safe to host multiple unrelated backends, each addressed by
its own hostname, without making their application or data services public.
Ladle must remain available at its current staging hostname throughout the
migration apart from a short, reversible public-port handoff.

## Decision

Run one app-neutral Caddy gateway as a dedicated Compose project under
`/opt/platform/gateway`. It alone publishes TCP 80 and 443 and UDP 443. Caddy
routes requests by hostname across an external Docker network named
`platform-edge`.

Each backend remains a separate Compose project with its own private networks,
secrets, volumes, resource limits, logs, health checks, and backups. Only that
backend's HTTP edge service joins `platform-edge`, using a globally unique
network alias. For Ladle, the alias is `ladle-edge`.

This is preferred over installing Caddy directly on Ubuntu because the
container image can remain pinned and the existing Docker-based operational
model is preserved. It is preferred over extending Ladle's Caddy because
deploying or removing Ladle must not control ingress for unrelated apps.

## Components

### Shared gateway

- A pinned Caddy container owns the public HTTP and HTTPS ports.
- Root-owned gateway configuration and environment files live outside app
  releases.
- Every validated preparation writes a fresh opaque deployment generation into
  the root-only gateway environment. Compose propagates that non-secret value
  to the gateway environment and labels the resulting container so management
  can compare prepared and running revisions without inspecting or hashing a
  secret.
- Caddy certificate and runtime data use gateway-owned named volumes.
- A bounded logging policy, resource limits, a read-only root filesystem, and
  a configuration health check match the existing hardened deployment.
- Route configuration is validated before a reload or replacement.

### Ladle

- The app-owned Caddy service and Caddy volumes are removed from the Ladle
  Compose overlay.
- The Ladle `edge` service keeps its private `edge` network and additionally
  joins the external `platform-edge` network as `ladle-edge`.
- PostgreSQL, Redis, MinIO, API, workers, and Beat remain inaccessible from the
  shared network and from host ports.
- Ladle deployment and health operations verify its edge service but no longer
  manage the shared Caddy lifecycle.

### Future backends

Each future backend receives a unique hostname, Compose project name, gateway
alias, secrets directory, volumes, health checks, resource limits, backup
policy, and route file. It exposes no host port and connects only its HTTP edge
service to `platform-edge`.

## Request Flow

1. DNS resolves a backend hostname to the VPS IPv4 and IPv6 addresses.
2. The shared Caddy gateway terminates TLS and selects a route by hostname.
3. Caddy forwards to that app's unique edge alias on `platform-edge`.
4. The edge service applies app-specific request policy and forwards only to
   services on that app's private network.

For the temporary Ladle staging hostname, the shared gateway preserves the
existing staging-key gate, private-object route, forwarded host, and HSTS
header. Unknown hostnames receive no application route.

## Secrets and Isolation

The Ladle staging access key moves to a root-readable gateway environment file
because the gateway enforces that policy. It is never placed in a release,
shell output, or documentation. Other app secrets remain owned by their app.

Only HTTP edge containers join the shared network. Databases, queues, object
stores, APIs, and workers never join it. Docker services continue to run with
bounded privileges and without public host mappings.

## Migration and Rollback

The gateway files, external network, volumes, and Ladle route are created and
validated before changing the live listener. During the handoff:

1. Stop only Ladle's current Caddy container.
2. Start the shared gateway on the same public ports.
3. Verify TLS, staging access, security headers, IPv4 and IPv6, application
   health, and public listeners.
4. Deploy the Ladle revision that no longer owns Caddy.

If the shared gateway does not pass its immediate checks, stop it and restart
the existing Ladle Caddy container. The app and data containers are not
recreated during the listener handoff.

### Management contract

The root-only gateway manager runs from one immutable, root-owned
`/opt/ladle/releases/<full-revision>` tree and accepts only `prepare`,
`activate`, `rollback`, or `status`.

- `prepare` validates the exact release marker and source metadata, creates an
  absent operations authority lock atomically with POSIX noclobber semantics
  and a `077` umask, then validates and pins the winning inode without replacing
  it when first-time prepares race. It extracts only the Ladle hostname and
  staging access key without sourcing the app environment, generates a fresh
  opaque prepared revision, and atomically installs root-owned assets under
  `/opt/platform/gateway`. It takes the blocking exclusive authority lock
  before reading mutable inputs and holds it through installation.
  Existing unrelated route files are preserved. Compose and pinned-Caddy
  validation run without publishing ports or stopping a container.
- `activate` revalidates the installed files, secret metadata, shared-network
  contract, unique `ladle-edge` ownership, backend readiness, and exact legacy
  Caddy identity while holding the same exclusive authority lock. It always
  force-recreates only the gateway service so mounted configuration and rotated
  environment values enter a new container, then accepts success only when the
  healthy container's opaque revision matches the prepared revision. Recovery
  retains a verified shared listener when Compose left one serving; otherwise
  it stops the failed replacement and restores the exact legacy listener.
- `rollback` stops only the validated shared gateway, then waits for the
  preserved legacy listener under the exclusive authority lock. Recovery is
  armed before starting legacy even when both listeners began stopped. If the
  legacy container starts but remains unhealthy, it is stopped before the
  shared gateway is restarted. A failed shared recovery reports the unresolved
  listener risk explicitly.
- `status` takes a blocking shared authority lock using a separate descriptor
  and revalidates its pinned identity, so concurrent readers remain compatible
  while deployments and handoffs stay exclusive. It is otherwise read-only:
  it reports preparation, active-listener state, runtime-revision currency, and
  both container health states without parsing or displaying secret values or
  the opaque revision. It fails for a stale runtime revision, foreign
  ownership, or contradictory listener ownership.

## Failure Handling

- Invalid gateway configuration blocks activation.
- A failed active-gateway replacement retains a verified serving shared
  container when possible or restores the exact legacy listener.
- A failed port handoff triggers the documented rollback.
- Ladle health checks distinguish shared-gateway availability from application
  health.
- New app onboarding cannot change an existing route without an explicit,
  validated configuration update.

## Verification

- Add failing deployment tests before changing Compose or operations behavior.
- Validate rendered Compose configurations and Caddy configuration.
- Run the complete VPS deployment unit-test suite and shell syntax checks.
- Run `git diff --check` before every commit.
- On the VPS, verify the shared gateway is the sole owner of ports 80 and 443.
- Confirm Ladle's data services have no host mappings and are absent from
  `platform-edge`.
- Re-run the external staging verifier over IPv4 and IPv6.
- Confirm Ladle health and backup timers remain active and the latest backup
  checksum remains valid.
