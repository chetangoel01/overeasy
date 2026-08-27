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
| #6 (backend half) | Device binding survives sign-out | `b648aed` | fixed |
| #6 (iOS half) | Installation ID never rotated | `f203232` | fixed |
| #10 | Uncancelled sync task writes after wipe | `d49b549` | fixed |
| #5 | Imported recipes lost their notes | `_pending_` | fixed |

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

### iOS half — rotate the installation ID on sign-out

`InstallationIdentity` (`Ladle/Account/InstallationIdentity.swift`) is now the
single owner of the `ladle.installation.id` key. It mints the identifier on
first read, rotates it, and clears it for the `-reset-backend-session` launch
argument. `AuthClient` holds it and reads `installationIdentity.current` when
it builds a guest registration, so no caller passes an identifier in.

That last part is what makes the fix hold. Previously the identifier was read
once at bootstrap and threaded as a `String` through `LadleRuntime` ->
`RootView` -> `WelcomeView`; rotating the stored value would have left those
views holding the pre-rotation copy for the rest of the process. Removing the
parameter chain deletes the staleness rather than working around it.
`LibraryView` declared the same property and never used it, so it went too.

`AuthClient.signOut()` reads the signed-out account's kind before clearing the
Keychain and, for anything other than a guest, rotates the identifier and
resets the App Attest key (the key's client data binds the installation ID, so
a stale key would be rejected against the rotated one). `deleteAccount()`
rotates unconditionally — the server row is already gone. `AppAttestClient`
holds the identity instead of a `String` and reads it once per attestation
flow, so a challenge and its assertion always agree on the identifier.

The guest exemption matches the backend rule and the same reasoning: a guest
account's binding is its only credential.

### Verification

- `LadleTests/AuthClientTests.testSignOutRotatesTheInstallationIDOfARealAccount`
  registers a guest that the server reports as `apple`, signs out, and
  registers again, asserting the second request carries a different
  installation ID and that the attester was reset. Red state (rotation
  disabled): `XCTAssertNotEqual failed: ("Optional("855a05c9-...")") is equal
  to ("Optional("855a05c9-...")")` plus `XCTAssertTrue failed` for the
  attester. Green after the fix.
- `LadleTests/AuthClientTests.testSignOutKeepsTheInstallationIDOfAGuest` pins
  the exemption: a guest's identifier is unchanged and the attester is left
  alone. This test passes in both states by design — it guards the fix from
  overreaching, and would fail if rotation were made unconditional.

Commands:

```text
xcodegen generate
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
  -> LadleTests: 252 executed, 1 skipped, 0 failures
  -> LadleUITests: 21 executed, 0 failures
```

### Declined scope

Moving the installation ID from `UserDefaults` to the Keychain was considered
and declined. With rotation on the device and unbinding on the server, the
identifier is no longer a durable bearer credential for a real account, so the
migration would add a Keychain dependency and an upgrade path for no remaining
security gain.

## Finding #10 — a cancelled sign-out leaves the sync running

### The defect

`RecipeSyncService.startSync` runs the pull in an unstructured `Task` that
nothing ever cancelled. Sign-out wipes the local store and resets the cursor,
but a pull already on the wire carried an authorized token and finished
regardless: `applySyncPage` re-inserted the signed-out account's recipes into
the just-wiped store and `cursorStore.save` re-wrote the cursor sign-out had
just reset. The rows then survived the next sign-in, because a fresh session
starts at cursor 0 and so never takes the snapshot-reconcile path that would
have pruned them. `StoredRecipe` has no owner field, so the next account saw
the previous account's library.

The `Task.checkCancellation()` calls already in the push loop could not help:
no one was cancelling the task they ran in.

### The fix

`RecipeSyncService.cancelActiveSync()` cancels the run in flight **and awaits
its unwind** before returning. Firing the cancel without waiting would not
close the window — the task can sit between suspension points, and sign-out
would race it to the store anyway. `LadleRuntime.clearLocalSession()` is now
`async` and calls it before `libraryViewModel.clearLocalLibrary()`, so both
`signOut()` and `deleteAccount()` drain the sync before wiping.

The pull loop also gained `Task.checkCancellation()` after the page request
returns — once before `applySyncPage` and once before `cursorStore.save`.
Cancelling a URLSession call usually throws, but not if the response landed
just before the cancel; the explicit checks make "a cancelled run writes
nothing" true by construction rather than by timing.

### Verification

- `LadleTests/RecipeSyncServiceTests.testCancellingAnInFlightSyncAppliesNothingAndKeepsTheCursor`
  holds a pull open on a semaphore, runs the sign-out cancel, releases the
  response, and asserts nothing was applied and the cursor stayed at 0 — both
  right after the cancel returns and after the sync task itself finishes. Red
  state (cancel removed, matching the previous behaviour):
  `XCTAssertEqual failed: ("2") is not equal to ("0")` for the cursor and
  `XCTAssertTrue failed` for the applied-page assertion — the reviewer's
  scenario exactly. Green after the fix.
- `LadleTests/SwiftDataRecipeRepositoryTests.testWipingLocalDataClearsEverythingWithoutQueueingTombstones`
  fills the missing coverage for `wipeAllData`: recipes (synced and unsynced)
  and import jobs are gone, and — the property that matters for sign-out — no
  pending delete is left queued for the next push, so the server library is
  untouched. This is characterisation coverage of behaviour that was already
  correct, not a red-green fix.

```text
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -only-testing:LadleTests
  -> 254 executed, 1 skipped, 0 failures
```

## Finding #5 — every imported recipe lost its notes

`RecipeTemplate.instantiate` built its `RecipeDTO` without passing `notes`, so
the field defaulted to `[]` on every path that creates a recipe from a
template: cache hits, private completion, reimport, Discover detail and
Discover save. Extraction routes tips into `notes` and `build_reviewed_template`
stores them on the template, so the data was extracted, cached, and then
discarded on the last hop. `RecipeTemplate.from_recipe` dropped them the same
way, losing them a second time whenever a stored recipe was re-templated.

Both now carry the notes through. `instantiate` goes via a new
`RecipeTemplate.recipe_notes()` because the two models disagree on bounds: a
template holds whatever extraction produced (unbounded, so already-cached
entries stay loadable), while `RecipeDTO.notes` caps at `MAX_RECIPE_NOTES`
entries of `MAX_RECIPE_NOTE_LENGTH` characters — both now named constants in
`ladle/contracts/recipes.py` rather than inline literals, so the clamp cannot
drift from the contract. Overflow is dropped rather than raising, because a
`ValidationError` here would turn silent data loss into a failed import.

### Verification

`tests/unit/recipes/test_template_clone.py` (new file), red before the fix:

```text
test_instantiate_carries_the_extracted_notes_onto_the_recipe   FAILED
test_from_recipe_keeps_notes_when_a_stored_recipe_is_re_templated  FAILED
test_instantiate_drops_notes_a_recipe_could_never_hold         FAILED
  -> AssertionError: assert 0 == 100 / where 0 = len([])
```

Green after, together with `uv run pytest -q -m "not live_provider and not
chaos"` at 699 passed and `uv run mypy --strict ladle` clean.
