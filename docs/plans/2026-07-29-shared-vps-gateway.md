# Shared VPS Gateway Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move public TLS ingress out of Ladle into a shared Caddy gateway so this VPS can host multiple isolated backends by hostname.

**Architecture:** A dedicated `platform-gateway` Compose project owns ports 80 and 443 and routes to uniquely named HTTP edge containers over the external `platform-edge` Docker network. Ladle keeps its private networks and state services; only its Nginx edge joins the shared network as `ladle-edge`.

**Tech Stack:** POSIX shell, Docker Engine and Compose, Caddy 2, Pytest, YAML

---

### Task 1: Specify the shared gateway topology

**Files:**
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Create: `Backend/deploy/vps/gateway/docker-compose.yml`
- Create: `Backend/deploy/vps/gateway/Caddyfile`
- Create: `Backend/deploy/vps/gateway/routes/ladle.caddy`

**Step 1: Write the failing topology tests**

Add constants for the gateway directory, Compose file, main Caddyfile, and
Ladle route. Add a gateway loader and assert:

```python
gateway = yaml.safe_load(GATEWAY_PROFILE.read_text())
service = gateway["services"]["gateway"]
assert service["ports"] == ["80:80", "443:443", "443:443/udp"]
assert re.fullmatch(r"caddy:[^@]+@sha256:[0-9a-f]{64}", service["image"])
assert service["networks"] == ["platform-edge"]
assert gateway["networks"]["platform-edge"] == {
    "external": True,
    "name": "platform-edge",
}
```

Require bounded logging, CPU/memory/PID limits, a read-only root filesystem,
dropped capabilities, `no-new-privileges`, persistent gateway-owned volumes,
and a Caddy validation health check.

Assert the main Caddyfile imports route fragments and the Ladle route preserves
the hostname variable, staging-key gate, signed-object bypass, HSTS, forwarded
host, fallback 404, and `ladle-edge:8082` upstream.

**Step 2: Run the tests to verify they fail**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py -q
```

Expected: FAIL because the gateway assets do not exist.

**Step 3: Add the minimal gateway assets**

Create a pinned, hardened Caddy service whose only network is the external
`platform-edge` network. Mount:

```yaml
- ./Caddyfile:/etc/caddy/Caddyfile:ro
- ./routes:/etc/caddy/routes:ro
- platform-caddy-data:/data
- platform-caddy-config:/config
```

The main Caddyfile imports `/etc/caddy/routes/*.caddy`. The Ladle route uses
`{$LADLE_PUBLIC_HOSTNAME}` and `{$LADLE_TUNNEL_ACCESS_KEY}` and proxies only to
`ladle-edge:8082`.

**Step 4: Run the new gateway-only tests**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py \
  -k 'gateway or caddy_requires' -q
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Backend/tests/unit/deploy/test_vps_profile.py \
  Backend/deploy/vps/gateway
git diff --check
git commit -m "feat: add shared VPS gateway assets"
```

### Task 2: Detach public ingress from Ladle

**Files:**
- Modify: `Backend/deploy/vps/docker-compose.yml`
- Modify: `Backend/deploy/vps/deploy.sh`
- Modify: `Backend/deploy/vps/provision.sh`
- Modify: `Backend/.dockerignore`
- Delete: `Backend/deploy/vps/Caddyfile`
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`

**Step 1: Keep the new Ladle lifecycle assertions red**

Replace the app-owned Caddy assertions with tests that require:

```python
assert "caddy" not in _profile()["services"]
assert all(
    service.get("ports", []) == []
    for service in _profile()["services"].values()
)
assert _profile()["services"]["edge"]["networks"]["platform"]["aliases"] == [
    "ladle-edge"
]
assert _profile()["networks"]["platform"] == {
    "external": True,
    "name": "platform-edge",
}
```

Require the deployment script to roll out only the app services and never run
`compose ... caddy`. Require it to check that `platform-edge` exists before
service mutation. Require provisioning to create the external network
idempotently.

**Step 2: Run the narrow lifecycle tests to verify they fail**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py \
  -k 'exposes_only or named_state or deploy_validates or provisioning' -q
```

Expected: FAIL on the old Caddy service, volumes, rollout, and missing shared
network setup.

**Step 3: Make Ladle an ingress consumer**

Remove the `caddy` service and Ladle Caddy volumes. Add this network attachment
to `edge`:

```yaml
networks:
  edge:
    ipv4_address: 172.31.0.3
  platform:
    aliases:
      - ladle-edge
```

Declare:

```yaml
platform:
  external: true
  name: platform-edge
```

Remove the Caddy rollout from `deploy.sh`. Before `compose config`, fail safely
unless `docker network inspect platform-edge` succeeds. Make `provision.sh`
create `platform-edge` only when it is absent. Remove the obsolete Caddyfile
Docker-build-context exception and delete the app-owned Caddyfile.

**Step 4: Run the Ladle profile tests**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py -q
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Backend/deploy/vps Backend/.dockerignore \
  Backend/tests/unit/deploy/test_vps_profile.py
git diff --check
git commit -m "refactor: detach Ladle from public ingress"
```

### Task 3: Add repeatable gateway preparation and rollback

**Files:**
- Create: `Backend/deploy/vps/gateway/manage.sh`
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`

**Step 1: Write failing management tests**

Require a root-only POSIX shell entry point with
`prepare|activate|rollback|status`. Static and executable tests must verify:

- fixed paths `/opt/platform/gateway`, `/etc/platform/gateway.env`, and
  `platform-edge`;
- no sourcing or printing of `/etc/ladle/ladle.env`;
- exact extraction of only `LADLE_PUBLIC_HOSTNAME` and
  `LADLE_TUNNEL_ACCESS_KEY`;
- root-owned atomic installation and mode `0600` for the gateway environment;
- idempotent external-network creation;
- `docker compose config --quiet` and `caddy validate` before activation;
- the Ladle edge is present on `platform-edge` before the listener handoff;
- only the legacy Ladle Caddy container is stopped;
- a failed shared-gateway start stops the new gateway and restarts the legacy
  container;
- explicit `rollback` performs the same reversible listener swap;
- no secret values are written to stdout or command arguments.

**Step 2: Run the management tests to verify they fail**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py \
  -k 'gateway_management' -q
```

Expected: FAIL because `manage.sh` is absent.

**Step 3: Implement the minimal management script**

`prepare` installs the gateway assets, securely derives the two required
gateway variables from the existing Ladle environment, creates
`platform-edge`, and validates both Compose and Caddy without taking the
public ports. Gateway `prepare` creates and validates
`/var/lib/ladle/locks/authority.lock` before pushing the detached release; it
must be a canonical root-owned `0600` regular file. This upgrade prerequisite
lets the detached release install its stable launcher without a missing-lock
window on the existing VPS.

`activate` verifies that `ladle-edge` is reachable, stops the known legacy
`ladle-caddy-1` container, starts the `platform-gateway` project, and confirms
its container health. A trap restores the legacy listener on failure. Keep the
stopped legacy container during the first verification window so rollback does
not depend on rebuilding an old release.

`rollback` stops the shared gateway and restarts the preserved legacy
container. `status` reports both listener containers without reading secrets.

**Step 4: Run the management and shell tests**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py \
  -k 'gateway_management' -q
sh -n deploy/vps/gateway/manage.sh
dash -n deploy/vps/gateway/manage.sh
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Backend/deploy/vps/gateway/manage.sh \
  Backend/tests/unit/deploy/test_vps_profile.py
git diff --check
git commit -m "feat: manage shared VPS gateway"
```

### Task 4: Teach Ladle operations about the shared boundary

**Files:**
- Modify: `Backend/deploy/vps/operations.sh`
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`

**Step 1: Write failing operations tests**

Update health expectations so `check_containers` covers only Ladle containers.
Require a separate `gateway_compose` helper and `check_gateway` function that
validate the fixed gateway paths, the gateway container, and Caddy
configuration. Status may show the gateway project separately; Ladle logs must
not claim ownership of unrelated gateway logs.

**Step 2: Run the operations tests to verify they fail**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py \
  -k 'health or operations' -q
```

Expected: FAIL because operations still execute Caddy inside the Ladle project.

**Step 3: Separate gateway and app health**

Remove `caddy` from Ladle service loops and log commands. Add strict gateway
path metadata checks before running:

```sh
docker compose \
  --project-name platform-gateway \
  --project-directory /opt/platform/gateway \
  --env-file /etc/platform/gateway.env \
  -f /opt/platform/gateway/docker-compose.yml
```

Have `health_check` run `check_gateway` separately from Ladle container and
Nginx checks. Preserve the existing local TLS certificate-expiry check.

**Step 4: Run all VPS deployment tests**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy/test_vps_profile.py -q
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Backend/deploy/vps/operations.sh \
  Backend/tests/unit/deploy/test_vps_profile.py
git diff --check
git commit -m "fix: monitor the shared VPS gateway"
```

### Task 5: Document and locally verify the migration

**Files:**
- Modify: `docs/verification/2026-07-28-vps-staging.md`
- Create: `docs/verification/2026-07-29-shared-vps-gateway.md`

**Step 1: Document the operator flow**

Record the topology, fixed paths, prepare/activate/rollback commands, expected
brief listener handoff, future-backend onboarding contract, and the exact
verification evidence to capture. State that only HTTP edge services may join
`platform-edge`.

**Step 2: Run the full local verification**

Run:

```bash
cd Backend
.venv/bin/pytest tests/unit/deploy -q
find deploy/vps -type f -name '*.sh' -exec sh -n {} +
find deploy/vps -type f -name '*.sh' -exec dash -n {} +
.venv/bin/ruff check tests/unit/deploy
cd ..
git diff --check
git status --short
```

Expected: all deployment tests and checks PASS; only intended files are
modified.

**Step 3: Commit**

```bash
git add docs/verification
git diff --check
git commit -m "docs: prepare shared gateway migration"
```

### Task 6: Migrate the live VPS with rollback ready

**Files:**
- Update after verification:
  `docs/verification/2026-07-29-shared-vps-gateway.md`

**Step 1: Reconfirm the current listener and application health**

Run read-only SSH checks for `sudo ladle-operations health`, current Compose
services, deployment revision, `platform-edge`, and public listeners. Record
the legacy Caddy container ID for rollback without printing secrets.

**Step 2: Prepare the gateway**

Create `platform-edge` explicitly on the existing VPS. From the
gateway-preparation revision, run:

```bash
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh prepare
```

Expected: assets and secret metadata validate; the gateway is prepared but does
not yet own public ports, and the authority lock is installed safely. Only
after that succeeds, push the exact detached Git revision. The new Ladle edge
is connected as `ladle-edge`, and the legacy Caddy still serves staging.

**Step 3: Activate with automatic rollback**

Run:

```bash
sudo /opt/ladle/current/Backend/deploy/vps/gateway/manage.sh activate
```

Expected: `platform-gateway-gateway-1` becomes healthy and the legacy
`ladle-caddy-1` becomes stopped. If activation fails, the command restores the
legacy container and exits nonzero.

**Step 4: Verify the public and private boundaries**

Verify:

- only SSH and the shared gateway listen publicly on TCP 22, 80, and 443 and
  UDP 443;
- IPv4 and IPv6 TLS validate for the staging hostname;
- missing or incorrect staging keys receive 404;
- the correct staging key passes the complete external verifier;
- HSTS and all existing security headers remain present;
- only `ladle-edge` from the Ladle project is on `platform-edge`;
- PostgreSQL, Redis, MinIO, API, workers, and Beat have no host mappings;
- `sudo ladle-operations health` reports healthy;
- health and backup timers are active;
- the latest backup checksum validates.

Do not print the staging key or any environment file.

**Step 5: Record evidence and commit**

Add the exact deployed revision, container/network state, external verifier
result, health result, listener audit, backup evidence, rollback state, and
known follow-ups to the verification document.

```bash
git add docs/verification/2026-07-29-shared-vps-gateway.md
git diff --check
git commit -m "docs: verify shared VPS gateway"
```
