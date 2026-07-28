# VPS Staging-to-Production Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deploy a fresh, access-key-protected Overeasy staging backend on the
OVH VPS and leave a tested, documented path to production promotion.

**Architecture:** Add a VPS Compose override around the existing FastAPI,
Celery, PostgreSQL, Redis, MinIO, worker-egress, and hardened Nginx services.
Caddy terminates public TLS and enforces the staging key before forwarding to
Nginx; repository-owned scripts provision Ubuntu, deploy exact Git revisions,
validate backups, and monitor the host.

**Tech Stack:** Ubuntu 26.04 LTS, Docker Engine/Compose, Caddy, Nginx, POSIX
shell, systemd, FastAPI, Celery, PostgreSQL 16, Redis 7, MinIO, pytest.

---

## Preconditions and safety

- Work only in the dedicated
  `/Users/chetangoel/Documents/recipe-app/.worktrees/vps-staging-deployment`
  worktree on `codex/vps-staging-deployment`.
- Preserve the unrelated dirty `main` worktree.
- Use @test-driven-development for repository changes,
  @systematic-debugging for unexpected failures, and
  @verification-before-completion before each completion claim.
- Never open the OVH one-time-password URL automatically, paste its value into
  chat, pass secrets on a command line, or print a generated secret.
- Do not change DNS until the key-protected edge passes a direct-IP TLS
  preflight.
- Do not copy Mac mini PostgreSQL, Redis, MinIO, user, recipe, or cache state.
- Do not mark the VPS production. `LADLE_ENVIRONMENT` remains `development`
  until the separate production credential, TLS data-service, App Attest, and
  recovery gates pass.

### Task 1: Teach the external verifier about the staging access key

**Files:**

- Modify: `Backend/tests/unit/deploy/test_staging_verifier.py`
- Modify: `Backend/scripts/verify_staging.py`
- Modify: `Backend/docs/ci-and-production-verification.md`

**Step 1: Write the failing tests**

Add coverage proving that a configured key:

```python
def test_staging_verifier_authenticates_checks_and_rejects_missing_key() -> None:
    seen: list[str | None] = []

    def respond(request: httpx.Request) -> httpx.Response:
        key = request.headers.get("X-Ladle-Tunnel-Key")
        seen.append(key)
        if key != "stage-secret":
            return httpx.Response(404)
        return staging_response(request)

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:
        result = verify(
            base_url="https://api.ladle.app",
            client=client,
            staging_access_key="stage-secret",
        )

    assert "stagingAccess" in result.checks
    assert None in seen
    assert "wrong-stage-secret" in seen
    assert "stage-secret" in seen
```

Also test that `_secret(Path)` rejects an empty file and that the CLI exposes
`--staging-access-key-file`, never `--staging-access-key`.

**Step 2: Run the tests and verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_staging_verifier.py
```

Expected: failure because `verify` has no `staging_access_key` argument and no
`stagingAccess` check.

**Step 3: Implement the smallest verifier change**

- Add `staging_access_key: str | None = None` to `verify`.
- Pass the correct key to every normal request.
- When set, send two extra liveness probes: one without the header and one with
  `wrong-<key>`, requiring `404` for both.
- Read the real key only from `--staging-access-key-file`.
- Strip the file value, reject an empty value, and never include it in output.
- Document the file-based invocation.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_staging_verifier.py
uv run ruff check scripts/verify_staging.py tests/unit/deploy/test_staging_verifier.py
uv run mypy scripts/verify_staging.py
git diff --check
```

Expected: all commands pass.

**Step 5: Commit**

```bash
git add Backend/scripts/verify_staging.py \
  Backend/tests/unit/deploy/test_staging_verifier.py \
  Backend/docs/ci-and-production-verification.md
git commit -m "test: verify guarded VPS staging access"
```

### Task 2: Add the guarded VPS Compose profile

**Files:**

- Create: `Backend/tests/unit/deploy/test_vps_profile.py`
- Create: `Backend/deploy/vps/docker-compose.yml`
- Create: `Backend/deploy/vps/Caddyfile`
- Modify: `Backend/.dockerignore`

**Step 1: Write the failing profile tests**

Create `test_vps_profile.py` with contract tests that require:

```python
BACKEND = Path(__file__).parents[3]
PROFILE = BACKEND / "deploy" / "vps" / "docker-compose.yml"


def test_vps_profile_exposes_only_the_guarded_tls_edge() -> None:
    profile = PROFILE.read_text()
    caddy = (PROFILE.parent / "Caddyfile").read_text()

    assert '80:80' in profile
    assert '443:443' in profile
    assert profile.count("ports: !reset []") >= 3
    assert "api.ladle.app" not in caddy
    assert "{$LADLE_PUBLIC_HOSTNAME}" in caddy
    assert "X-Ladle-Tunnel-Key" in caddy
    assert "{$LADLE_TUNNEL_ACCESS_KEY}" in caddy
    assert "/ladle-private/*" in caddy
    assert "respond 404" in caddy
    assert "reverse_proxy edge:8082" in caddy


def test_vps_profile_keeps_state_private_and_bounded() -> None:
    profile = PROFILE.read_text()

    for service in (
        "postgres",
        "redis",
        "minio",
        "minio-init",
        "caddy",
        "edge",
        "api",
        "worker-egress",
        "worker",
        "beat",
    ):
        assert f"  {service}:" in profile
    assert 'LADLE_ENVIRONMENT: "development"' in profile
    assert 'LADLE_OBJECT_STORAGE_ENABLED: "true"' in profile
    assert "https://${LADLE_PUBLIC_HOSTNAME}" in profile
    assert "network_mode: service:worker-egress" in profile
    assert "NET_ADMIN" in profile
    assert "privileged: true" not in profile
    assert "read_only: true" in profile
    assert "max-size: 10m" in profile
    assert "max-file: 3" in profile
```

Require named volumes for PostgreSQL, Redis, MinIO, and Caddy data; fixed
private edge addresses; a trusted-proxy CIDR containing only Nginx; and
resource ceilings compatible with 8 GB RAM.

**Step 2: Run the tests and verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
```

Expected: failure because the VPS profile does not exist.

**Step 3: Implement the minimal profile**

- Reuse the pinned `deploy/mac-mini/edge.Dockerfile`,
  `deploy/mac-mini/nginx.conf`, `deploy/mac-mini/egress.Dockerfile`, and
  `deploy/mac-mini/worker-egress.sh`; do not duplicate them.
- Pin Caddy by immutable image digest.
- Publish only Caddy ports `80` and `443`; remove all base API/MinIO host
  ports.
- Route `/ladle-private/*` without the staging header so MinIO can validate
  its signed query string.
- Require an exact `X-Ladle-Tunnel-Key` for every other path and return `404`
  otherwise.
- Forward authorized traffic to the existing Nginx `8082` listener, which
  strips the staging header before FastAPI.
- Set the external MinIO signing endpoint to
  `https://${LADLE_PUBLIC_HOSTNAME}`.
- Keep audio, frame analysis, and server-media fallback off for the first
  staging rollout.
- Keep the worker inside the existing egress sidecar.
- Add only the VPS Compose file and Caddyfile to `.dockerignore` exceptions
  needed by their build contexts.

**Step 4: Validate the profile**

Create a temporary, mode-`0600` env file outside the repository containing
non-secret test placeholders, then run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py \
  tests/unit/deploy/test_mac_mini_profile.py \
  tests/unit/deploy/test_container_hardening.py
docker compose --env-file /tmp/ladle-vps-test.env \
  -f docker-compose.yml \
  -f deploy/vps/docker-compose.yml config --quiet
git diff --check
```

Expected: tests pass and merged Compose configuration validates. Remove the
temporary env file afterward.

**Step 5: Commit**

```bash
git add Backend/.dockerignore Backend/deploy/vps \
  Backend/tests/unit/deploy/test_vps_profile.py
git commit -m "feat: add guarded VPS runtime profile"
```

### Task 3: Add idempotent Ubuntu provisioning and SSH hardening

**Files:**

- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Create: `Backend/deploy/vps/provision.sh`
- Create: `Backend/deploy/vps/harden-ssh.sh`
- Create: `Backend/deploy/vps/host-validation.sh`
- Create: `Backend/deploy/vps/ladle-docker-user.rules`

**Step 1: Write failing script-contract tests**

Require `provision.sh` to:

- verify Ubuntu `26.04`;
- install Docker's official GPG key and `docker.sources`;
- install `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin`, and `docker-compose-plugin`;
- create `/opt/ladle/releases`, `/etc/ladle`, `/var/backups/ladle`, and
  `/var/lib/ladle`;
- install persistent IPv4 and IPv6 firewall rules;
- allow established traffic plus TCP `22`, `80`, and `443`;
- place container exposure rules in `DOCKER-USER`;
- avoid Docker's convenience installer.

Require `harden-ssh.sh` to:

- fail unless a public-key login marker supplied by the caller is present;
- write an SSH drop-in with `PermitRootLogin no`,
  `PasswordAuthentication no`, and `KbdInteractiveAuthentication no`;
- run `sshd -t` before reloading;
- preserve the active session until a second key-authenticated session passes.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
```

Expected: missing provisioning and hardening scripts.

**Step 3: Implement the scripts**

Use `set -eu`, `umask 077`, explicit absolute directories, and idempotent
package/rule installation. Do not use `curl | sh`. Do not delete Docker state
or change SSH authentication before the public key is installed and tested.

The firewall rule file must default-drop unsolicited host traffic and
explicitly reject unexpected Docker-published ports while permitting return
traffic for the application and worker.

The implemented firewall update alternates between two owned chains. It
fully prepares the inactive chain before installing its `DOCKER-USER` hook,
then removes the previous hook, so an interrupted update retains at least one
equivalent fail-closed policy. The SSH reload similarly defers termination
signals only while it reloads or restores the drop-in; when the transaction
returns, the on-disk policy and running daemon are synchronized. Executable
fake-iptables and injected SSH callback tests cover first install, reruns,
duplicate-hook recovery, failures on either side of hook installation,
pre-transaction signals, in-transaction signals, and reload rollback.
Rollback state is cleared only after the prior drop-in is restored
successfully. If restoration fails, cleanup retains the backup path and
pending state, reports the recovery failure, and leaves the active SSH
session open for manual repair.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
sh -n deploy/vps/provision.sh
sh -n deploy/vps/harden-ssh.sh
sh -n deploy/vps/host-validation.sh
sh -n deploy/vps/ladle-docker-user.rules
git diff --check
```

Repeat the syntax checks with `dash -n`, and run `shellcheck` on all four
scripts if installed. Expected: all available checks pass.

**Step 5: Commit**

```bash
git add Backend/deploy/vps Backend/tests/unit/deploy/test_vps_profile.py
git commit -m "feat: provision and harden Ubuntu VPS host"
```

### Task 4: Add exact-revision release and secret-safe deployment

**Files:**

- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Create: `Backend/deploy/vps/push.sh`
- Create: `Backend/deploy/vps/deploy.sh`
- Create: `Backend/deploy/vps/initialize-env.sh`
- Create: `Backend/deploy/vps/set-secret.sh`

**Step 1: Write failing deployment-contract tests**

Require the scripts to prove:

- `push.sh` refuses a dirty Git tree and identifies `git rev-parse HEAD`;
- it transfers only `git archive` output, not `.git`, `.env`, `.private`, test
  caches, or the working directory;
- releases land at `/opt/ladle/releases/<full-commit>`;
- `initialize-env.sh` creates `/etc/ladle/ladle.env` atomically with mode
  `0640`, a dedicated group, and random values for JWT, encryption, metrics,
  PostgreSQL, MinIO, and staging access;
- no script prints the generated values;
- `set-secret.sh` accepts an allowlisted key and reads its value from standard
  input rather than argv;
- `deploy.sh` validates Compose, starts data services, initializes MinIO, runs
  Alembic, then replaces worker/API/edge services;
- rollout waits for local readiness and Celery worker health;
- `COMPOSE_PROJECT_NAME=ladle` keeps volumes stable across release directories;
- `current` changes only after a successful rollout;
- a failed rollout leaves `current` at its previous revision.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
```

Expected: missing release and environment scripts.

**Step 3: Implement the scripts**

Keep the control flow direct:

```text
push exact commit -> initialize env if absent -> deploy release
-> public/local readiness -> atomically update current symlink
```

Use the existing migration and MinIO initialization commands. Do not copy the
Mac database or volumes. Default the worker to fake mode when no provider key
has been installed; `set-secret.sh LADLE_OPENROUTER_API_KEY` enables live
staging explicitly.

Write the staging key to `/etc/ladle/staging-access-key` with mode `0640` for
the owner to use in a private device build and external verifier. Do not print
it.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
sh -n deploy/vps/push.sh
sh -n deploy/vps/deploy.sh
sh -n deploy/vps/initialize-env.sh
sh -n deploy/vps/set-secret.sh
git diff --check
```

Expected: all checks pass.

**Step 5: Commit**

```bash
git add Backend/deploy/vps Backend/tests/unit/deploy/test_vps_profile.py
git commit -m "feat: deploy exact revisions to VPS"
```

#### Task 4 implementation checkpoint

- `push.sh` refuses any tracked or untracked change, archives the exact full
  commit into a private local temporary file, preflights noninteractive remote
  sudo, uploads through a random mode-`0700` remote directory, and installs a
  root-owned, non-writable release without copying Git metadata, local
  environments, private files, or caches.
- `initialize-env.sh` creates the fresh staging environment and separate
  staging-access-key file atomically at mode `0640`. It validates and repairs
  an interrupted two-file initialization without sourcing or printing either
  file. The default worker provider remains `fake`.
- `set-secret.sh` accepts only allowlisted provider keys and exactly one safe
  value on standard input. Installing `LADLE_OPENROUTER_API_KEY` changes the
  provider mode to `live` in the same atomic rewrite.
- `deploy.sh` uses the stable `ladle` Compose project, validates the immutable
  exact release and environment, then gates activation on data health, image
  build, bucket initialization, Alembic migration, service replacement, API
  and edge readiness, a bounded Celery ping, and a fresh Celery Beat container
  remaining stable for a bounded observation window. `/opt/ladle/current`
  changes only after every gate succeeds.
- Provisioning creates separate root-owned mode-`0600` deployment and
  environment lock files under the persistent, canonical root-only
  `/var/lib/ladle/locks` directory. They survive reboot and avoid Ubuntu's
  `/var/lock` symlink into volatile `/run`. Initialization, provider-secret
  updates, and the complete deployment transaction share the environment lock,
  so no deploy can read a partially rewritten environment. Deployment acquires
  its nonblocking deployment lock before the blocking environment lock.
- The worker rollout removes the namespace-sharing worker before replacing
  `worker-egress`, waits for that donor container, and then force-recreates the
  dependent worker. A donor failure stops the rollout before the dependent is
  started.
- `/var/lib/ladle/deployment-state` is atomically updated at mode `0644` before
  service mutation and for each deployment phase. After every readiness gate,
  `active`/`complete` state is durably precommitted before the current symlink
  changes; it becomes authoritative only when it names the same revision as
  `/opt/ladle/current`. An activation failure overwrites the precommit with
  `failed` and leaves the prior current release. A handled signal immediately
  after the symlink move recognizes matching state and current as committed,
  instead of falsely reporting failure or rolling either side back.
- Each server phase is streamed to the invoking terminal and written without
  command or secret content to the root-owned mode-`0640`
  `/var/log/ladle/setup.log`. A second SSH session can follow it with
  `sudo tail -F /var/log/ladle/setup.log`.
- The provisioning script now keeps `/opt/ladle/releases` root-owned at mode
  `0755`, and upload normalizes a candidate to a traversable root-owned mode
  `0755` before running the exact release's executable permission validator.
  Rerunning provisioning cannot weaken completed releases.
- Local verification covers 54 VPS deployment tests, including executable
  permission-boundary, lock-serialization, concurrent secret-update,
  deployment-state, namespace-sharing worker rollout, and Beat stability
  harnesses, plus POSIX and Dash parsing, Ruff, the complete deploy-unit suite,
  and whitespace checks. ShellCheck was not installed in the local workspace
  and remains an Ubuntu-side verification item.
- Resume with Task 5. No VPS, DNS, environment, credential, or live service
  state was changed while implementing this checkpoint.

### Task 5: Add Linux health, backup, and systemd operations

**Files:**

- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Create: `Backend/deploy/vps/operations.sh`
- Create: `Backend/deploy/vps/install-operations.sh`
- Create: `Backend/deploy/vps/ladle-health.service`
- Create: `Backend/deploy/vps/ladle-health.timer`
- Create: `Backend/deploy/vps/ladle-backup.service`
- Create: `Backend/deploy/vps/ladle-backup.timer`

**Step 1: Write failing operations tests**

Require:

- a five-minute health timer;
- a nightly backup timer;
- `pg_dump -Fc`;
- non-empty archive validation with `pg_restore --list`;
- `sha256sum`;
- mode `0600`;
- 35-day retention;
- a 20 GiB free-disk floor;
- checks for Caddy, Nginx, API, worker, Beat, PostgreSQL, Redis, and MinIO;
- certificate-expiry and backup-freshness checks;
- bounded journald/container output;
- `Persistent=true` on the backup timer;
- no macOS paths, `launchctl`, `osascript`, `shasum`, or BSD `stat -f`.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
```

Expected: missing operations files.

**Step 3: Implement the Linux operations path**

Port only the relevant behavior from `deploy/mac-mini/local-operations.sh`.
Use Linux `stat -c`, `sha256sum`, `systemctl`, and `journalctl`. Keep state and
backups outside the release checkout. Alerts may log transitions during
staging; production promotion requires an external notification destination.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
sh -n deploy/vps/operations.sh
sh -n deploy/vps/install-operations.sh
systemd-analyze verify deploy/vps/*.service deploy/vps/*.timer
git diff --check
```

If `systemd-analyze` is unavailable on macOS, record it as a VPS verification
step rather than representing it as passed locally.

**Step 5: Commit**

```bash
git add Backend/deploy/vps Backend/tests/unit/deploy/test_vps_profile.py
git commit -m "feat: monitor and back up VPS staging"
```

**Task 5 implementation checkpoint (2026-07-28):**

- The operations path gives an operator four bounded, on-demand commands:
  `health`, `backup`, `status [LINES]`, and `logs [LINES]`. The health timer
  runs every five minutes, while the persistent backup timer runs nightly.
- Health validates that root-owned deployment state says `active`/`complete`
  and names the same immutable revision as `/opt/ladle/current`. It then checks
  the Caddy and Nginx configurations, API readiness, Celery worker and Beat,
  PostgreSQL, Redis, MinIO, public-certificate lifetime, and the freshness and
  checksum of the latest backup. This exposes interrupted or mixed rollouts
  instead of treating running containers as authoritative.
- Backups use PostgreSQL's custom archive format through the stable `ladle`
  Compose project and the root-owned environment file path; credential values
  are never arguments or output. Each dump must be nonempty and pass
  `pg_restore --list` before its mode-`0600` archive and SHA-256 sidecar are
  atomically named. The path refuses to start below 20 GiB free and retains 35
  days of archives. Every dump, validation, permission, exact 64-hex digest,
  checksum, timestamp, publish, sync, retention, metadata, transition, cleanup,
  and final output step propagates failure explicitly even when POSIX
  `errexit` is suppressed by a caller. A one-file publish failure removes its
  orphan; a completely published validated pair is retained but never reported
  as successful when a later operational step fails.
- An on-demand or timer backup takes the same nonblocking root deployment lock
  at `/var/lib/ladle/locks/deploy.lock` used by `deploy.sh` before reading the
  authoritative release or running `pg_dump`. It fails clearly when a
  deployment owns the lock, so an archive cannot race migrations or a mixed
  service rollout.
- Host state, transition records, logs, and backups remain under
  `/var/lib/ladle`, `/var/log/ladle`, and `/var/backups/ladle`, outside release
  checkouts. Staging alerts record only fixed, secret-free state transitions.
  Production promotion still requires an external notification destination.
- `install-operations.sh` accepts a full revision, requires that exact
  root-owned, non-writable release and its immutable marker, stages and verifies
  the complete binary/unit set before swapping any target, and retains exact
  rollback copies until daemon reload and both timer activations succeed.
  Swap, reload, enable, start, and handled-signal failures restore the prior
  complete set and timer intent; a second signal is ignored during
  reconciliation. If restoring any prior target fails, all remaining root-only
  `.ladle-backup.*` recovery copies are preserved beside their exact targets,
  staging cleanup is attempted independently, and the fixed diagnostic reports
  an incomplete rollback without claiming that prior state was restored.
  First-install target-removal failure instead warns that mixed/new targets
  require root inspection, while a stage-only cleanup failure reports that
  targets were restored and only `.ladle-stage.*` artifacts may remain.
  Successful timer start is the commit point; signal handling remains active
  through post-commit cleanup, and cleanup failure or interruption returns
  committed success with a warning instead of falsely rolling back the live
  installation.
- Executable shell harnesses cover real lock contention, health transition
  deduplication and recovery, backup success plus 15 injected failure stages,
  installer first-install and upgrade failures at six transaction phases, and
  signal rollback, including restore failure, a repeated rollback signal, and a
  post-commit cleanup signal. The focused profile contains 102 tests and the
  complete deploy-unit set contains 139. POSIX `sh` and Dash parsing for every
  VPS script, Ruff for the changed Python contract, and `git diff --check` also
  pass. `systemd-analyze` is unavailable in the macOS workspace, so real unit
  verification remains an explicit Ubuntu-side check before enabling timers;
  installer tests use a command shim only to exercise rollback behavior and do
  not represent local systemd verification.
- Affected components are `deploy/vps/operations.sh`,
  `install-operations.sh`, provisioning/deployment/secret scripts, the backup
  unit, and `tests/unit/deploy/test_vps_profile.py`. No VPS, SSH, DNS,
  credential, systemd, backup, or live service state was accessed or changed
  at this checkpoint.

### Task 6: Document deployment, recovery, and production promotion

**Files:**

- Create: `Backend/docs/deployment/vps.md`
- Modify: `Backend/README.md`
- Modify: `README.md`

**Step 1: Write the documentation contract**

Extend `test_vps_profile.py` to require the runbook to contain:

- the selected host and empty-state decision;
- one-time password handling and public-key bootstrap;
- DNS A/AAAA records;
- staging-key retrieval without printing;
- provider-secret installation through standard input;
- deploy, status, logs, backup, restore, rollback, and key-rotation commands;
- explicit statement that OVH snapshots are not database-aware backups;
- production blockers: external PostgreSQL restore, off-host object state,
  TLS credentialed data services, Apple/Google/App Attest, tracing, real-device
  checks, and removal of the staging gate;
- no literal credential values.

**Step 2: Verify red**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
```

Expected: missing VPS runbook.

**Step 3: Write the runbook**

Keep commands copyable but use placeholders for account-owned values. Mark
which commands run on the Mac and which run on the VPS. Include deterministic
rollback and an empty-server PostgreSQL restore drill.

**Step 4: Verify green**

Run:

```bash
cd Backend
uv run pytest -q tests/unit/deploy/test_vps_profile.py
git diff --check
```

Expected: all checks pass.

**Step 5: Commit**

```bash
git add Backend/docs/deployment/vps.md Backend/README.md README.md \
  Backend/tests/unit/deploy/test_vps_profile.py
git commit -m "docs: add VPS staging operations runbook"
```

### Task 7: Run the local milestone verification

**Files:**

- Modify only if a failure exposes a real defect in the preceding tasks.

**Step 1: Run focused infrastructure checks**

```bash
cd Backend
uv run pytest -q tests/unit/deploy
uv run ruff format --check .
uv run ruff check .
uv run mypy ladle scripts
```

Expected: all pass.

**Step 2: Run the complete backend suite**

```bash
cd Backend
uv run pytest -q
```

Expected: the suite passes with only documented credential-gated skips.

**Step 3: Validate shell and Compose artifacts**

```bash
cd Backend
sh -n deploy/vps/*.sh
docker compose --env-file /tmp/ladle-vps-test.env \
  -f docker-compose.yml \
  -f deploy/vps/docker-compose.yml config --quiet
git diff --check
```

Remove the temporary env file. Expected: all checks pass.

**Step 4: Confirm checkpoint**

```bash
git status --short --branch
git log --oneline --decorate -8
```

Expected: clean `codex/vps-staging-deployment` branch with task-sized commits.

### Task 8: Establish secure SSH access

**External state:** OVH VPS `135.148.42.60`; no repository files.

**Step 1: Generate a dedicated key locally**

Create an Ed25519 key in a task-specific path under the user's SSH directory,
with a passphrase chosen through the local terminal. Do not overwrite an
existing key and do not display the private key.

**Step 2: Owner retrieves the OVH password**

The owner opens the OVH one-time link personally and types the password only
into the local SSH prompt.

**Step 3: Install the public key**

Use `ssh-copy-id` or an equivalent single-purpose command for
`ubuntu@135.148.42.60`.

**Step 4: Verify a second key-only session**

Run:

```bash
ssh -o PreferredAuthentications=publickey \
  -o PasswordAuthentication=no ubuntu@135.148.42.60
```

Expected: successful login without the OVH password.

**Step 5: Record the host key**

Compare the first-seen fingerprint with the OVH KVM console before accepting
it permanently. Stop if they differ.

### Task 9: Provision, configure DNS, and deploy staging

**External state:** VPS and DNS for `ladle.app`.

**Step 1: Inspect the untouched host**

Record OS release, architecture, disk, memory, listening ports, SSH settings,
pending updates, and existing firewall state. Expected: Ubuntu 26.04, amd64,
and no unexpected public service.

**Step 2: Run provisioning**

Transfer and run the committed provisioner with `sudo`. Reboot if the kernel or
Docker install requires it, then verify key-only SSH again.

**Step 3: Harden SSH**

Run the committed hardener only after the second key-only session passes.
Verify password and root login are rejected while key login remains available.

**Step 4: Upload and deploy the exact revision**

Run `deploy/vps/push.sh` from the clean worktree. Expected: empty PostgreSQL and
MinIO state, healthy internal services, fake-provider staging, and no public
route before DNS/TLS.

**Step 5: Set DNS**

Point:

```text
api.ladle.app A    135.148.42.60
api.ladle.app AAAA 2604:2dc0:121::64f
```

Use a short TTL for the first rollout. Verify authoritative and public
resolution before continuing.

**Step 6: Verify the guarded TLS boundary**

Read `/etc/ladle/staging-access-key` into a local mode-`0600` file without
printing it, then run:

```bash
cd Backend
uv run python scripts/verify_staging.py https://api.ladle.app \
  --staging-access-key-file /path/to/private/key-file
```

Expected: TLS, security headers, key rejection, readiness, hidden endpoints,
authentication, and request-size checks pass.

### Task 10: Enable live extraction and record deployment evidence

**Files:**

- Create: `docs/verification/2026-07-28-vps-staging.md`

**Step 1: Install the provider key without exposing it**

Use `set-secret.sh LADLE_OPENROUTER_API_KEY` with the value supplied through
standard input. Set `LADLE_WORKER_PROVIDER_MODE=live` through the same
allowlisted mechanism, then redeploy the exact revision.

**Step 2: Run live staging journeys**

Verify:

- guest bootstrap and token refresh;
- one YouTube import;
- one TikTok or Instagram import;
- worker completion and recipe retrieval;
- signed thumbnail retrieval without the staging header;
- recipe sync;
- account deletion;
- worker restart and Redis restart recovery;
- nightly backup plus an on-demand validated backup.

Provider calls may consume quota. Stop and diagnose rather than repeatedly
retrying a platform-blocked source.

**Step 3: Run a restore drill**

Restore the new dump into an isolated empty PostgreSQL 16 container and verify
schema revision and expected row counts. This proves the VPS backup path
without importing any Mac data.

**Step 4: Write the verification record**

Record revision, commands, redacted host facts, DNS, TLS, firewall exposure,
container health, tests, live journeys, backup name/digest, restore outcome,
known limitations, and production blockers. Do not include keys, tokens,
passwords, signed URLs, or provider response bodies.

**Step 5: Verify and commit**

```bash
git diff --check
git add docs/verification/2026-07-28-vps-staging.md
git commit -m "docs: verify OVH VPS staging deployment"
git status --short --branch
```

Expected: clean branch and a recoverable verified deployment checkpoint.

## Production follow-up

Do not remove the staging access gate as part of this plan. Create a separate
production-promotion design/plan after the staging soak. That work must resolve
the current production validator's TLS credential requirements for PostgreSQL
and Redis, externally durable versioned object storage, off-provider database
backups, App Attest, Apple/Google identity, tracing, provider rotation, and
real-device distribution signing before `LADLE_ENVIRONMENT=production`.
