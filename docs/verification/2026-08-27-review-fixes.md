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
| #5 | Imported recipes lost their notes | `cb7e366` | fixed |
| #1 + #24 | Cancelled imports: downgrade and wire enum | `2de8bb2` | fixed |
| #9 | Rejected delete wedged every later sync | `5eb298e` | fixed |
| (new) | Tombstones lost on the next save of the row | `1af3345` | fixed |
| #7 | Push acknowledgement erased an in-flight edit | `4dfbad2` | fixed |
| #8 | Editor numbers parsed against the wrong locale | `1733928` | fixed |
| #2 | A limiter outage became an API outage | `bcd5ac2` | fixed |
| #4 | Concurrent edits at the same revision both won | `_pending_` | fixed |

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

## Findings #1 and #24 — the cancelled import status

These two are the same gap seen from opposite ends: 0014 taught the database
about `cancelled`, but neither the wire contract nor the migration's own
downgrade was taught with it.

### #24 — a cancelled job could not be serialized

`AdmissionService._idempotent_job` matches on job ID *or* idempotency key with
no status filter, so a client re-POSTing after a lost response matched the job
it had since cancelled. `ImportStatus("cancelled")` then raised `ValueError`,
which no route handler catches, and the client got a retryable HTTP 500 —
which it retried, reproducing the 500 indefinitely.

`ImportStatus` now carries `CANCELLED`, and `ImportJobResponse`'s validator
treats it like `PARSING` for the recipe-ID rule: a cancelled import may not
expose a candidate recipe.

On the Swift side `RemoteImportStatus` gained `cancelled` so the payload
decodes instead of failing with `APIError.decoding`, and
`RemoteImportJobDTO.importStatus()` throws the new
`RemoteContractError.importCancelled` rather than the generic
`invalidImportStatus`. The domain `ImportStatus` deliberately did **not** gain
a case: that would ripple through every import switch in the library UI, and
how a cancelled job should present is part of the ImportCoordinator
cancellation cluster (#30–#32). The distinct error is the seam that work will
catch — until then a cancelled job surfaces as a generic import failure rather
than a decode crash, which is strictly better but not yet right.

### #1 — the 0014 downgrade deleted cancelled jobs

`DELETE FROM import_jobs WHERE status = 'cancelled'` cascaded through
`import_quota_events`, `import_dispatch_outbox`, `import_dead_letters`,
`recipe_slot_reservations` and `provider_attempts` — silently refunding the
user's monthly import quota and destroying the billing and audit trail.

The downgrade now remaps instead of deleting: `status = 'failed'` with
`failure_reason = COALESCE(failure_reason, 'parserUnavailable')` and
`stage = 'failed'`. `failed` is the closest state the pre-0014 set can
express, and the reason has to be non-NULL because `ImportJobResponse` rejects
a failed job without one — remapping to a row that then 500s on serialization
would just move the bug. The approximation is documented in the migration and
confined to the rollback path.

### Verification

- `tests/integration/test_migrations.py::test_cancelled_import_downgrade_preserves_jobs_and_their_quota_events`
  inserts a cancelled job plus its quota event, downgrades to 0013, and
  asserts both survive. Red: `AssertionError: the cancelled job was deleted by
  the downgrade`.
- `tests/api/test_import_admission.py::test_import_is_committed_before_dispatch_and_can_be_polled`
  now continues past the cancellation into a re-POST of the identical
  submission. Red: `ValueError: 'cancelled' is not a valid ImportStatus`
  surfacing as a 500. Green: 202 with `status == "cancelled"` and no recipe ID.
- `Packages/LadleCore/Tests/LadleCoreTests/RemoteContractTests.swift::cancelledImportDecodesAndReportsItselfAsCancelled`
  decodes a cancelled job payload and expects `importCancelled`. Red at
  compile time (`type 'RemoteContractError' has no member 'importCancelled'`).

```text
uv run pytest -q -m "not live_provider and not chaos"  -> 700 passed
uv run mypy --strict ladle                             -> clean
swift test --package-path Packages/LadleCore           -> 46 tests passed
xcodebuild build -scheme Ladle                         -> BUILD SUCCEEDED
```

## Finding #9 — one rejected delete wedged the device forever

The `.upsert` push branch caught `syncConflict` and preserved it; the
`.delete` branch caught nothing. A recipe edited on another device and then
deleted locally produced a `syncConflict` on `DELETE /v1/recipes/{id}`, which
threw straight out of `performSync` — before the pull loop, which is the whole
back half of a sync. `markDeleteSynced` never ran, so the row kept
`pendingMutationKey = "delete"` and every later sync re-sent the same rejected
DELETE. The device never pulled another remote change again, and
`RemoteFailure` maps `syncConflict` to `.unknown`, whose `canRetry()` is true,
so the UI kept offering a retry that could not work.

The `.delete` branch now mirrors the `.upsert` one: a `syncConflict` becomes a
preserved conflict the user can resolve, and the push phase carries on into
the pull. Resolving it `keepLocal` rebases the tombstone on the server's
revision so the next sync's DELETE succeeds; `acceptRemote` brings the recipe
back. Any other remote error still propagates, as before.

`preserveConflict` took a whole `localRecipe` but only ever used its `id` —
and a delete has no local recipe to pass. It now takes `localRecipeID`, which
serves both branches.

### Verification

`LadleTests/RecipeSyncServiceTests.testRejectedDeletePreservesAConflictInsteadOfWedgingSync`
pushes a pending delete against a 409 `syncConflict` and asserts the conflict
is preserved, the pull still applied both changes, the cursor advanced, and no
delete was marked synced. Red (conflict arm disabled): the sync throws
`remote(RemoteErrorDTO(code: syncConflict …))` out of `synchronize()` before
the pull. Green after the fix, with `-only-testing:LadleTests` at 255 executed,
1 skipped, 0 failures.

## Beyond the 45 — deleted recipes came back on the next save

Found while building the red test for #7, using only pre-existing production
code: `saveRemote`, `deleteRecipe`, then `preserveConflict` on the same
recipe. The tombstone held right after the delete and was gone after the next
save of that row — the recipe was fetchable again, while its pending `.delete`
mutation remained. Not one of the 45 findings; recorded here rather than in
`.review/`.

The cause is a name collision: `StoredRecipe` declared a stored property
`isDeleted`, which `PersistentModel` already vends. The schema attribute was
reset to `false` by the next save of the row.

This is not a corner case. Any later write to a deleted-but-unpushed recipe
resurrects it in the library, and finding #9's fix makes that path routine —
a rejected delete now *always* preserves a conflict on the tombstoned row, so
without this fix every delete conflict would have resurrected the recipe it
was about.

The property is now `isTombstoned`, carrying `@Attribute(originalName:
"isDeleted")` so existing stores migrate rather than starting over. The name
also says what the flag means, which the old one did not: the row is a local
tombstone awaiting its DELETE push, not a deleted object.

### Verification

`LadleTests/SwiftDataRecipeRepositoryTests.testTombstoneSurvivesALaterSaveOfTheSameRow`
deletes a synced recipe, preserves a conflict on it, and asserts the recipe
stays gone from both the single fetch and the list while the delete stays
pending. Red before the rename (`XCTAssertNil failed: "Recipe(id: …)"`), green
after. Full `-only-testing:LadleTests` run: 256 executed, 1 skipped, 0
failures — the rename touched `applySyncPage`'s tombstone branches too and
changed nothing else.

A grep of the `@Model` types for other members that shadow `PersistentModel`
API (`hasChanges`, `modelContext`, `persistentModelID`) found none.

## Finding #7 — the push acknowledgement erased edits made while it flew

`markUpsertSynced` handed the server's copy straight to `saveRemote`, which
overwrote the local payload and cleared `pendingMutationKey`. The MainActor is
free during the PUT, so the user can edit in that window: tap the favourite
heart, and while that PUT is in flight rename the recipe. The response — which
carries the *pre-rename* recipe — then overwrote the rename and cleared the
pending mutation, so it was never pushed either. The edit vanished on every
device, with no error shown.

`markUpsertSynced` now takes the recipe that was actually pushed and adopts
the server's copy only if the row still matches it: not tombstoned, still
pending the same upsert, same decoded payload. Otherwise the local change
stays and is rebased onto the revision the server just assigned, so the next
sync pushes it at the right base.

The row-is-gone branch is a deliberate no-op rather than an insert: the only
way there is the user hard-deleting a never-synced recipe mid-flight, and
re-inserting the server's copy would resurrect it. The missing server-side
delete in that case belongs to finding #28 and is not fixed here.

### Verification

Three tests in `SwiftDataRecipeRepositoryTests`, red with the match check
forced true:

```text
testAcknowledgingAPushKeepsAnEditMadeWhileItWasInFlight
  XCTAssertEqual failed: ("Optional("One-Pot Lemon Orzo")")
    is not equal to ("Optional("Miso Ramen")")
  XCTAssertEqual failed: ("[]") is not equal to ("[…upsert(… "Miso Ramen" …)]")
testAcknowledgingAPushDoesNotResurrectARecipeDeletedInFlight
  XCTAssertNil failed: "Recipe(id: 690D61EC…)"
  XCTAssertEqual failed: ("[]") is not equal to ("[…delete(… baseRevision: 2)]")
```

`testAcknowledgingAnUnchangedPushAdoptsTheServerCopy` pins the ordinary path,
so the fix cannot degrade into never adopting the server's copy. Full
`-only-testing:LadleTests`: 259 executed, 1 skipped, 0 failures.

## Finding #8 — the editor parsed numbers in the wrong locale

Editor numeric fields use a `.decimalPad`, which renders the *current
locale's* decimal separator. Both parsers — `RecipeDraft`'s and
`RecipeEditorViewModel.validate()`'s — used a fixed `en_US_POSIX` locale, so a
French user typing "1,5" into Servings got `Decimal(string:)` stopping at the
comma and returning 1. Validation used the same parser, saw a valid 1, and
raised nothing. The recipe was saved and synced at one serving, and every
per-serving nutrition figure derived from it was wrong. The same truncation
hit every nutrition field.

The two duplicated parsers are now one `EditorNumber.decimal(_:locale:)` built
on `NumberFormatter`, which reads the locale's own separator *and* digits
(Arabic-Indic included) and returns nil for anything it cannot parse whole.
That second property matters as much as the first: "1.2.3" and "12abc"
previously truncated to 1.2 and 12 and saved silently; they are now rejected
and reported by validation. `RecipeEditorViewModel` carries the locale
(injectable, defaulting to `.current`) and passes it into
`draft.recipe(updatedAt:locale:)`, so validation and persistence can never
disagree about how a field was read.

### Verification

Locale behaviour was checked empirically before committing to `NumberFormatter`
(en_US, fr_FR, de_DE, ar_EG against "1,5", "1.5", "1.500", "1,500", "12abc",
"1.2.3", "٣٫٥"): each parses its own convention and rejects the rest, and
grouping separators resolve per locale.

`LadleTests/RecipeEditorViewModelTests`, red against the old POSIX parser:

```text
testCommaDecimalLocaleSavesTheYieldTheUserTyped
  XCTAssertEqual failed: ("Optional(1)")  is not equal to ("Optional(1.5)")
  XCTAssertEqual failed: ("Optional(12)") is not equal to ("Optional(12.5)")
testUnparseableNumbersAreRejectedRatherThanTruncated
  XCTAssertNil failed: "Recipe(… servings: 1.2 … calories: Optional(12) …)"
```

Green after: `-only-testing:LadleTests` at 261 executed, 1 skipped, 0 failures.

## Finding #2 — a Redis blip took the whole API down

`RateLimitService.enforce` ran the backend call bare, and the global
middleware caught only `RateLimitExceeded`. A `redis.exceptions.ConnectionError`
from a restart or failover therefore escaped `enforce` *before* `call_next`
was ever reached, hit the catch-all handler, and returned 500 for every
request on every path — including `GET /health/live`, which is meant to be
dependency-free. Production mandates rate limiting, so a transient Redis blip
became a total outage plus failing liveness checks and an orchestrator restart
loop.

`RedisTokenBucketBackend` now wraps its `eval` and raises the new
`RateLimitBackendUnavailable`, keeping provider-specific client exceptions
from leaking out of the limiter. `RateLimitService.enforce` catches it, logs a
warning naming the buckets, and returns — serving the request unlimited. The
limiter is a guard on the service, not the service; `RateLimitExceeded` is an
answer, and this is the absence of one, so the two are separate types and only
the second fails open. Every route that calls `enforce` directly gets the same
degradation, not just the middleware.

### Verification

`tests/api/test_rate_limit_wiring.py::test_an_unreachable_rate_limit_store_degrades_instead_of_failing_requests`
builds the app with a backend that always raises and asserts `/health/live`
answers 200 and `POST /v1/auth/guest` still registers. Red with the catch
disabled: `assert client.get("/health/live").status_code == 200` fails on the
liveness probe — the finding's exact claim.

```text
uv run pytest -q -m "not live_provider and not chaos"  -> 701 passed
uv run ruff check ladle tests                          -> All checks passed
uv run mypy --strict ladle                             -> clean
```

## Finding #4 — two devices editing at once, one edit silently gone

`RecipeService.upsert` and `delete` read the recipe with a plain `SELECT` and
then wrote it, and the resulting `UPDATE` carries no revision predicate.
Sessions run at READ COMMITTED, so two devices PUTting the same recipe at
`baseRevision=3` both read revision 3, both passed the optimistic-concurrency
check, and the second's UPDATE — after blocking on the first's row lock —
overwrote it. Both clients got HTTP 200, and two `recipe_changes` rows both
claimed `recipe_revision=4`, so no sync consumer could tell an edit was
dropped.

`RecipeRepository.find` now takes `for_update`, and both `upsert` and `delete`
pass it. The check and the write become one atomic step: the second writer
blocks on the `SELECT`, re-reads revision 4 after the first commits, and
raises `SyncConflict` — the same answer the client already knows how to
resolve. `save_discovered` and `lock_recipe_capacity` already locked this way;
these two paths were the outliers.

### Verification

`tests/integration/recipes/test_recipe_service.py::test_concurrent_updates_at_the_same_base_revision_cannot_both_win`
runs a real second writer on its own connection while the first transaction is
open, then asserts the second raised `SyncConflict`, the stored title is the
first writer's, and the change log holds revisions `[1, 2]` with no duplicate.
Red before the lock:

```text
AssertionError: the second writer overwrote the first at the same base revision
```

```text
uv run pytest -q -m "not live_provider and not chaos"  -> 702 passed
uv run mypy --strict ladle                             -> clean
```
