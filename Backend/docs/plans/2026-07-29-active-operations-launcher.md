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
