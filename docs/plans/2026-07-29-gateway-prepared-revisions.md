# Gateway Prepared Revisions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to
> implement this plan task-by-task.

**Goal:** Ensure every shared-gateway activation applies the latest validated
configuration and environment while preserving a verified public-listener
fallback.

**Architecture:** `prepare` writes a fresh opaque non-secret generation into
the root-only gateway environment. Compose propagates it as an environment
value and container label. `activate` force-recreates only the gateway service
and verifies health, listener bindings, and generation; activation and rollback
share the existing listener-restoration primitive when a transition fails.

**Tech Stack:** POSIX shell, Docker Compose, Caddy, pytest.

---

### Task 1: Capture stale-runtime and Compose propagation failures

**Files:**

- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Modify: `Backend/deploy/vps/gateway/docker-compose.yml`

1. Extend the fake Docker state with container identity, environment, route,
   and generation metadata while keeping secrets out of the command trace.
2. Add a Compose contract test requiring the generation environment and label.
3. Add executable tests that activate, prepare changed routes or rotated
   hostname/key values, activate again, and require a new healthy container
   carrying the new generation and inputs.
4. Add a status test that rejects a healthy container whose generation differs
   from the prepared generation without printing either value or a secret.
5. Run the new tests and confirm they fail because activation returns early and
   Compose has no generation contract.

### Task 2: Capture replacement and stopped/stopped recovery failures

**Files:**

- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`
- Modify: `Backend/deploy/vps/gateway/manage.sh`

1. Add an active-replacement failure test that requires either the old verified
   shared listener or exact healthy legacy listener to be serving at exit.
2. Add stopped/stopped rollback tests for unhealthy legacy with successful
   shared recovery and with shared recovery failure.
3. Run the tests and confirm the active replacement remains stale and the
   stopped/stopped path leaves no verified listener.

### Task 3: Implement opaque prepared revisions and forced activation

**Files:**

- Modify: `Backend/deploy/vps/gateway/manage.sh`
- Modify: `Backend/deploy/vps/gateway/docker-compose.yml`
- Modify: `Backend/tests/unit/deploy/test_vps_profile.py`

1. Generate a fresh fixed-format random revision during each prepare and add it
   to the atomically installed root-only gateway environment.
2. Validate and commit that environment before mutating any live gateway asset,
   so an early failure changes nothing and a later failure invalidates the old
   runtime without attempting an unsafe environment-only rollback.
3. Validate the revision format without logging its value.
4. Propagate the revision through Compose environment and a dedicated label.
5. Inspect the label with container state and require a healthy, correctly
   bound, current-revision container for activation success and active status.
6. Replace the early activation success with bounded
   `up --force-recreate --no-deps` for only `gateway`.
7. On failure, retain an already healthy shared listener when available;
   otherwise stop/remove the failed replacement and start and verify exact
   legacy, falling back through the shared restoration primitive if needed.
8. Arm rollback recovery before legacy start regardless of initial shared
   running state.
9. Run focused tests until all new and existing gateway tests pass.

### Task 4: Verify and checkpoint

**Files:**

- Modify: `docs/plans/2026-07-29-shared-vps-gateway-design.md`

1. Run the full VPS deployment profile.
2. Run Ruff, `sh -n`, `/bin/dash -n`, and `git diff --check`.
3. Render Compose with non-secret test values and validate Caddy with the pinned
   image.
4. Scan the diff for known and fixture secrets, confirming none appear in
   commands, logs, or documentation.
5. Commit the verified change as `fix: apply prepared gateway revisions`.
