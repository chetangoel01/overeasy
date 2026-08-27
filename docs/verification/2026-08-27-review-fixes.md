# Review Fixes — 2026-08-27

**Branch:** `codex/review-fixes-2026-08-27`

**Base:** `main` at `686c9ee`

**Started:** August 27, 2026

**Status:** in progress

## Purpose

An adversarially-verified whole-codebase review produced 45 confirmed
findings. This record tracks the fixes landed on this branch, the failing
test that proved each defect, and the evidence that each fix closed it. It is
the single companion document for the run; each fix adds a section rather
than a new file.

Findings are worked in the review's own priority order: the sign-out security
cluster first, then the remaining HIGH findings, then MEDIUM findings grouped
by the code they touch.

## Fix ledger

| Finding | Area | Commit | State |
| --- | --- | --- | --- |
| #6 (backend half) | Device binding survives sign-out | `_pending_` | fixed |
| #6 (iOS half) | Installation ID never rotated | `_pending_` | pending |
| #10 | Uncancelled sync task writes after wipe | `_pending_` | pending |

## Finding #6 — sign-out leaves the device bound to the account

### The defect

`register_guest` (`Backend/ladle/auth/guest.py`) looks a device up by its
installation ID and issues a session for whatever user that row points at.
When a guest signs in with Apple or Google, `AccountMergeService` leaves that
device row pointing at the now-authenticated user. `DELETE /v1/auth/session`
only revoked the one session row, so an unauthenticated guest registration
replaying the same installation ID was handed a full Apple session — no Apple
credential presented. On the device side the installation ID is minted once
into `UserDefaults` and never rotated, so the next "Try as a guest" tap after
sign-out replayed it automatically.

The fix has two independent halves. The backend half closes the hole for any
caller holding the installation ID string. The iOS half stops the app from
carrying a signed-out account's identifier into the next session.

### Backend half — release the device binding on sign-out

`release_device_binding` (`Backend/ladle/auth/guest.py`) deletes the `devices`
row for the signed-out session's device, and `delete_session`
(`Backend/ladle/api/routes/auth.py`) calls it inside the same transaction as
the session revoke. `auth_sessions` and `app_attest_keys` both cascade from
`devices`, so every session and attestation key on that device is dropped
with it.

**A guest keeps its binding.** The installation ID is the only credential a
guest account ever has; unbinding on a guest sign-out would orphan that
library permanently with no way back. `release_device_binding` therefore
returns early when the bound user's kind is `guest`. This matches the sign-out
confirmation copy, which promises the library survives sign-out.

### Verification

Red-green, both halves of the discriminator:

- `tests/api/test_apple_auth.py::test_signing_out_of_an_apple_account_releases_the_device_binding`
  replays the reviewer's backend-only repro: guest registers, signs in with
  Apple, deletes the session, then re-registers as a guest on the same
  installation ID. Before the fix it returned `userKind == "apple"` for the
  signed-out account (`AssertionError: assert 'apple' == 'guest'`). After the
  fix it returns a new guest user, and the `devices` row points at that new
  user while the Apple user's own row survives untouched.
- `tests/api/test_guest_auth.py::test_guest_refresh_and_explicit_session_revocation`
  gained an assertion that a guest re-registering after sign-out gets the
  same `userID` back, so the guest exemption cannot silently regress.

Commands (from `Backend/`):

```text
uv run pytest -q tests/api/test_apple_auth.py tests/api/test_guest_auth.py   -> 7 passed
uv run pytest -q -m "not live_provider and not chaos"                        -> 696 passed, 5 deselected
uv run ruff check ladle tests                                               -> All checks passed
uv run mypy --strict ladle                                                  -> no issues in 121 source files
uv run ruff format --check <the four touched files>                         -> already formatted
```

**Pre-existing formatting drift, not introduced here:** repo-wide
`uv run ruff format --check .` reports 35 files that would be reformatted
under the locked ruff 0.16.0. None of them are touched by this branch —
`ruff format --check` passes on every file this branch changes. Reformatting
the other 35 would be a large unrelated diff and is left for a separate
change.
