# Active VPS Operations Launcher Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep host operations bound to the authoritative active release even
when operations assets are refreshed before deployment activation.

**Architecture:** Install a stable POSIX launcher at
`/usr/local/sbin/ladle-operations`. At every invocation it validates
`/opt/ladle/current`, the resolved immutable release, its revision marker, and
that release's operations script before replacing itself with the active
script. Refresh may update the launcher and version-neutral systemd units
before activation because dispatch remains controlled by `current`.

**Tech Stack:** POSIX shell, systemd units, pytest deployment-profile tests.

---

### Task 1: Specify the launcher trust boundary

**Files:**

- Create: `Backend/deploy/vps/operations-launcher.sh`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Add executable tests for valid dispatch, a `current` flip, every unsafe
   current/release/marker/script state, and argument preservation.
2. Run the focused tests and confirm they fail because the launcher is absent.
3. Implement a fixed-`PATH`, fail-closed POSIX launcher that validates:
   root-owned non-writable release metadata; an exact root-owned `0444`
   revision marker matching the resolved 40-character lowercase hexadecimal
   directory; and a root-owned executable non-symlink operations script.
4. Execute the validated script with `exec "$operations_script" "$@"`.
5. Re-run the focused tests to green.

### Task 2: Install and validate the stable launcher

**Files:**

- Modify: `Backend/deploy/vps/install-operations.sh`
- Modify: `Backend/deploy/vps/push.sh`
- Modify: `Backend/deploy/vps/deploy.sh`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Add failing assertions that release validation includes the executable
   launcher and that install/refresh source `/operations-launcher.sh`.
2. Update immutable release boundaries to require the launcher as a regular,
   executable file.
3. Stage the launcher—not release-specific `operations.sh`—at
   `/usr/local/sbin/ladle-operations`; retain `operations.sh` inside releases.
4. Re-run the focused tests to green.

### Task 3: Prove the activation boundary

**Files:**

- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Add the failing regression in which refresh succeeds but activation does
   not move `current`; invoking the installed launcher must dispatch the old
   implementation.
2. Move `current` to the candidate and verify the same installed launcher
   dispatches the new implementation.
3. Assert refreshed units remain version-neutral and continue to invoke only
   `/usr/local/sbin/ladle-operations`.
4. Run the regression to green without adding timer/service/backup actions to
   refresh mode.

### Task 4: Document, verify, and checkpoint

**Files:**

- Modify: `Backend/docs/deployment/vps.md`

**Steps:**

1. Explain that `current` authorizes operations dispatch and why
   refresh-before-activation is safe.
2. Run focused RED/GREEN evidence, the full deployment profile, Ruff, `sh -n`
   and `dash -n` for every changed shell script, and `git diff --check`.
3. Commit the coherent verified change as
   `fix: bind VPS operations to active release`.

### Task 5: Pin the validated launcher handoff

**Files:**

- Modify: `Backend/deploy/vps/operations-launcher.sh`
- Modify: `Backend/deploy/vps/operations.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Reproduce the bounded race between launcher validation and script execution.
2. Export the exact validated release immediately before `exec`, overwriting
   any inherited value.
3. Require state revision and one resolved `current` value to match that pin
   before deriving Compose paths or performing operations.
4. Verify stable releases, invalid pins, both mixed activation write orders,
   and the race before running the full profile.

### Task 6: Gate operations mutations on loaded authority

**Files:**

- Modify: `Backend/deploy/vps/operations.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Trace health, backup, logging, lock, cleanup, and file operations through
   both mixed activation states and the bounded launcher race.
2. Load a single deployment-state snapshot and fully validate the pinned
   release before any health or backup mutation.
3. Preserve transition logging and backup cleanup only after authority loads.
4. Treat inactive one-shot systemd units as expected while propagating other
   status, journal, and Compose errors.

### Task 7: Lock authority selection across legacy cutover

**Files:**

- Modify: `Backend/deploy/vps/operations-launcher.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Validate and open the canonical root-owned deployment lock without
   truncation, then take a blocking shared lock before resolving `current`.
2. Preserve the shared descriptor across `exec` so legacy operations cannot
   observe activation changes after dispatch.
3. Prove backup replaces the inherited descriptor before its nonblocking
   exclusive acquisition, including self-deadlock and competing-deploy cases.
4. Exercise unsafe lock metadata, launcher/deployment ordering, and the legacy
   upgrade path with bounded real-process regressions.

### Task 8: Separate authority and deployment exclusion

**Files:**

- Modify: `Backend/deploy/vps/provision.sh`
- Modify: `Backend/deploy/vps/install-operations.sh`
- Modify: `Backend/deploy/vps/deployment-lib.sh`
- Modify: `Backend/deploy/vps/deploy.sh`
- Modify: `Backend/deploy/vps/operations-launcher.sh`
- Modify: `Backend/deploy/vps/operations.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Modify: `docs/plans/2026-07-29-shared-vps-gateway.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Provision and validate a dedicated root-owned `authority.lock`.
2. Hold shared authority on launcher fd 7 and exclusive authority across only
   the operations-refresh/activation boundary.
3. Keep backup/deploy mutual exclusion on the independent `deploy.lock` fd 9.
4. Prove the lock order cannot deadlock and document the existing-VPS gateway
   preparation prerequisite.

### Task 9: Preflight authority metadata before deployment mutation

**Files:**

- Modify: `Backend/deploy/vps/deploy.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Steps:**

1. Validate `authority.lock` read-only after the persistent deployment and
   environment locks are acquired, before Compose or deployment-state changes.
2. Retain the late blocking exclusive authority acquisition and metadata
   revalidation immediately before operations refresh and activation.
3. Exercise missing, symlinked, wrong-owner, wrong-mode, valid, and
   post-preflight-swap paths with mutation tracing.

### Task 10: Pin authority-lock identity across acquisition

**Files:**

- Modify: `Backend/deploy/vps/deployment-lib.sh`
- Modify: `Backend/deploy/vps/deploy.sh`
- Modify: `Backend/deploy/vps/operations-launcher.sh`
- Modify: `Backend/docs/deployment/vps.md`
- Test: `Backend/tests/unit/deploy/test_vps_profile.py`

**Behavior and decisions:**

1. Snapshot and validate the authority pathname's device, inode, owner, and
   mode during deployment preflight without opening it.
2. Open fd 7 read-only, acquire the requested shared or exclusive lock, and
   require the snapshot to equal both the Linux `/proc/self/fd/7` target and
   the post-lock pathname identity.
3. Fail closed if procfs identity is unavailable or if a root-owned `0600`
   replacement inode appears at any acquisition seam. Keep fd 7 independent
   from the fd 9 deployment transaction and preserve their existing order.

**Verification:**

- Deterministic replacements before and after launcher open are rejected.
- Deployment rejects replacement after preflight, including while a launcher
  still holds the old inode, and never reaches operations refresh or
  activation.
- Stable acquisition preserves lock contents; unsafe metadata and the
  existing post-preflight mode-change race remain rejected.
