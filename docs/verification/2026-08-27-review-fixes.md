# Review Fixes — 2026-08-27

**Branch:** `codex/review-fixes-2026-08-27`

**Base:** `main` at `686c9ee`

**Started:** August 27, 2026

**Status:** paused — 13 of the 45 findings closed (32 open), plus one
defect the review had not found

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
| #4 | Concurrent edits at the same revision both won | `338967d` | fixed |
| #3 | Editing a recipe destroyed its stored image | `90e1775` | fixed |
| #20 + #21 | Observability middleware 500s and blind spots | `fda602d` | fixed |
| #33 | Cancelled requests reported as being offline | `fb9f643` | fixed |
| #30 + #31 + #32 | Import-cancellation cluster | `814ba45` | fixed |
| #28 | Delete during first upload came back | `d2ce167` | fixed |
| #27 | Remote delete mislabeled as a remote edit | `2969c5a` | fixed |
| #26 | Scrolling a focus-mode step changed the step | — | fixed |
| #12 | Malformed caption URL killed the whole import | `44b7b10` + `08a010b` | fixed |
| #13 | Hostile HTML pinned the worker for half an hour | `356aa66` | fixed |
| #11 | Reversed Whisper timings killed the transcription | `b590bb2` | fixed |
| #17 | Model decimal exponent bomb allocated gigabytes | `9a8158f` | fixed |
| #18 | Beat sweep deadlocked against import completions | `b215db5` | fixed |
| #19 | Uploaded thumbnails leaked on rollback or discard | `c863c5e` | fixed |
| #15 | One account could hoard multiple Apple identities | `0ee5069` + `c745cb8` | fixed |
| #14 | Import submission stalled every request on the worker | `1f2f0c1` | fixed |
| #16 | Recipe child tables scanned on every fetch | `a75771f` | fixed |
| #23 | One sync page fanned out to ~900 queries | `_pending_` | fixed |

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
under the locked ruff 0.16.0, all already drifted on `main`. Every hunk this
branch adds or modifies is formatted per that version. See the closing
section for the two touched files that still fail the whole-file check on
drift this branch did not introduce.

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

**Known residual, not fixed here.** `retry_after`'s own
`raise RuntimeError("Redis returned an invalid rate-limit result")` sits
outside the `try` this change added, so a malformed eval result still escapes
`enforce` and reproduces the same 500-storm by a rarer route. Same outage
class as #2; worth folding into the typed failure next session.

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

## Finding #3 — editing a recipe destroyed its object-storage image

`to_dto` renders an object-storage image as a six-hour presigned URL.
`replace_graph` then wrote every image back as `object_key=NULL,
remote_url=<that presigned URL>`, so any edit to a recipe — a title change, a
favourite toggle — replaced the durable key with a URL that expires. Six hours
later every fetch of that image 403s. Worse,
`CacheMaintenanceService.delete_unreferenced_thumbnails` guards on a
`RecipeImage.object_key` match; with the key gone the guard stops matching and
the sweep deletes the object the live recipe still points at.

A rendered locator is an output, not an input. `replace_graph` now snapshots
each existing image's `(object_key, remote_url)` before rebuilding the graph
and carries it forward by image id; only an image the recipe did not already
have is located by the URL the client supplied. That also keeps the
`ck_recipe_images_exactly_one_location` constraint satisfied without the
caller having to know which locator an image uses.

### Verification

`tests/integration/recipes/test_recipe_service.py::test_round_tripping_a_recipe_keeps_its_object_storage_image`
stores an image by object key, renders it through `to_dto` (asserting the
presigned URL really is what the client would receive), PUTs that DTO back
with an edited title, and checks the row still carries the key with no
`remote_url`. Red before the fix:

```text
AssertionError: assert None == 'thumbs/lemon-orzo'
  where None = <RecipeImage>.object_key
```

```text
uv run pytest -q -m "not live_provider and not chaos"  -> 703 passed
uv run mypy --strict ladle                             -> clean
```

## Findings #20 and #21 — the observability middleware

Two defects in one middleware, fixed together.

**#20 — a metrics label check 500ing real requests.** `record_http` ran the
request method through `_require`, the guard that keeps metric label
cardinality bounded, and `HEAD` was not in the six-item allowlist. The raise
happened *after* the response had been produced, so whatever the router
answered became a 500. The distinction that matters: every other `_require`
call guards an internal outcome enum, where a bad value is a programmer error
worth raising on. The request method comes from the caller — refusing it lets
anyone turn a served request into a 500. `HEAD` now joins the allowlist and
anything else is folded to a bounded `OTHER` label, so cardinality stays
capped without the request paying for it.

**#21 — failures missing from the record.** `call_next` was unwrapped, so an
unhandled exception skipped both the HTTP metric and the completion log. The
handler that turns it into a 500 sits outside this middleware, so those
requests — the ones an operator most needs — vanished from observability
entirely. The call is now wrapped: a raising handler records a 500 with the
elapsed duration and logs it as a failure before the exception is re-raised
for the error handler to answer. Both paths share one `record` helper rather
than duplicating the metric and log construction.

### Verification

`tests/unit/observability/test_middleware.py` (new file), all three red:

```text
test_head_requests_are_answered_and_counted_under_a_bounded_label
  ValueError: unbounded metric label: HEAD
test_an_unrecognised_method_is_folded_rather_than_failing_the_request
  ValueError: unbounded metric label: TRACE
test_a_failing_handler_is_still_recorded_and_logged
  assert 'status="5xx"' in ''   (nothing was recorded at all)
```

The HEAD test asserts 405 — the router's own answer for a GET-only route —
because the point is that the metrics layer no longer overrides it.

```text
uv run pytest -q -m "not live_provider and not chaos"  -> 706 passed
uv run mypy --strict ladle                             -> clean
```

## Milestone verification

Run at the end of the branch, on the iOS 26.5 simulator destination this
project has been using:

```text
swift test --package-path Packages/LadleCore
  -> 46 tests in 9 suites passed
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
  -> LadleTests:   261 executed, 1 skipped, 0 failures
  -> LadleUITests:  21 executed, 0 failures
xcodebuild build -project Ladle.xcodeproj -scheme LadleShare \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
  -> BUILD SUCCEEDED
cd Backend && uv run ruff check ladle tests alembic  -> All checks passed
cd Backend && uv run mypy --strict ladle             -> 121 source files clean
cd Backend && uv run pytest -q -m "not live_provider and not chaos"
  -> 706 passed, 5 deselected
```

## Finding #33 — cancelling a request read as "You're offline"

### The defect

`APIClient.perform`'s trailing `catch { throw APIError.transport }` swallowed
every non-`APIError`, including the two errors that mean "the awaiting task
was cancelled": `CancellationError` and `URLError(.cancelled)` (what URLSession
actually throws when its task is cancelled). `RemoteFailure` maps `.transport`
to `.offline`, so ordinary navigation-driven cancellation — switching tabs
while Discover's first load is in flight — painted a persistent "You're
offline" screen on a connected device, and every downstream
`catch is CancellationError` branch (DiscoverViewModel, WelcomeView,
AccountSheet, `performSync`'s `status.cancel()` arm) was unreachable. This is
also the root of finding #31: the ImportCoordinator's own cancellation arm
never saw a cancellation that landed inside a network call.

### The fix

`perform` now rethrows `CancellationError` as itself and converts
`URLError(.cancelled)` into `CancellationError`, so cancellation crosses the
API boundary typed as cancellation. Everything else still becomes
`APIError.transport`. The existing `catch is CancellationError` sites need no
changes — they were written for exactly this and now run. Consumers that
bypass `APIClient.perform` (`RemoteImageCache`, HealthKit export) are
unaffected.

### Verification

`LadleTests/APIClientTests.testCancelledRequestThrowsCancellationInsteadOfTransport`
stubs the session to fail with `URLError(.cancelled)` and asserts the request
throws `CancellationError`. Red before the fix:

```text
APIClientTests.swift:336: failed - Cancellation was reported as transport,
which renders as offline instead of being ignored
```

`testGenuineTransportFailureStillMapsToTransport` pins the other side —
`URLError(.notConnectedToInternet)` still reads as offline — so the fix
cannot over-match. Green after the fix with `-only-testing:LadleTests/
APIClientTests` (9 tests), plus DiscoverViewModelTests, RemoteFailureTests,
and RecipeSyncServiceTests to sweep the consumers of the changed mapping.

## Findings #30, #31, and #32 — the import-cancellation cluster

One defect surface: what "cancelled" means as it crosses from the network
layer into the coordinator's state machine.

### The defect

- **#30** — `cancelImport(jobID:)` deleted the durable row and then suspended
  at `service.cancel(...)`. The still-in-flight processing task resumed after
  the delete and re-saved the job — either the poll-loop save re-inserted it
  as a `.parsing` zombie (when the status response won the race), or
  `finishRemoteFailure` re-inserted it as `.failed(.networkUnavailable)`
  (when the cancelled request threw). The dialog promises the import "will
  stop processing and disappear from Inbox"; it reappeared instead.
- **#31** — with #33 unfixed, `process`'s `catch is CancellationError` arm was
  unreachable for any cancellation landing inside a network call, so ordinary
  task teardown (scene change, sheet dismissal) durably flipped a healthy
  `.parsing` job to `.failed(.networkUnavailable)`.
- **#32** — `resumePendingImports()` re-adopted every `.parsing` job,
  including the one the foreground already owned: it joined the in-flight
  task, then overwrote `operation` and `state` with the next pending job's,
  so the user's success screen was replaced by a spinner and `completedRecipe`
  ended up naming the share-extension recipe, not the one they imported.
- **The #1/#24 seam** — `RemoteContractError.importCancelled` was thrown but
  never caught, so a job the server reports as cancelled surfaced as
  `state = .persistenceFailed` ("Overeasy couldn’t save that import") with a
  phantom `.parsing` row left in the Inbox.

### The fix

Cancellation is made durable by ordering, distinguishable by type, and scoped
by ownership:

- `cancelImport` flips the task's cancel flag and deletes the row with **no
  suspension point between them**, so by the time the processing task can run
  again the cancellation is already durable. Row presence is what
  distinguishes teardown-cancel (row kept `.parsing`, resumed later) from
  user-cancel (row gone) — no separate token is needed. The remote cancel
  moved after `reset()`, runs only for a still-`.parsing` job with a
  `remoteJobID`, and is best-effort (`try?`): a cancel that succeeded locally
  no longer becomes `persistenceFailed` because the device was offline, and a
  job that finished in the race window keeps its recipe and never sends a
  remote cancel.
- `process` re-checks `Task.checkCancellation()` after **every** await before
  **every** save, and its `APIError` arms carry `where !Task.isCancelled` —
  any error caught on a cancelled task is treated as cancellation, closing
  both resurrection paths whatever the in-flight request threw.
- Published state (`state`, `completedRecipe`, `operationFailure`,
  `existingDuplicate`) is written only when the coordinator `owns(jobID:)`
  the job; durable saves and the import-ready notification happen for every
  job. A deliberate trade rides on this: a background-resumed job's failure
  no longer sets `operationFailure`, so the Inbox falls back to the durable
  `job.status` via `failure(for:)` — the richer report (request ID,
  rate-limit deadline) is reserved for the operation being watched.
- `resumePendingImports` skips any job whose task is already running,
  re-fetches each job before resuming it (an earlier iteration's await may
  have outlived it), adopts a job only when the coordinator is idle, and no
  longer stomps `state` when its own task is torn down mid-loop.
- `RemoteContractError.importCancelled` is caught: the durable row is deleted
  (the Inbox honors the cancellation) and, when owned, the new
  `ImportCoordinatorState.cancelled(jobID:)` presents it. AddRecipeSheet and
  ReimportSheet render it as "Import cancelled" — cancelled, not a failure,
  not a silent disappearance — and `refreshesLibrary` includes it so the
  Inbox badge updates. `DemoImportService` gained a `cancelled` link slug so
  demo builds can reach the state deterministically.

### Verification

Nine new `ImportCoordinatorTests` (plus one `DemoImportServiceTests`), red
first against the unfixed coordinator (`APIClient` already fixed, so the reds
below are coordinator defects, not #33's):

```text
testCancelDuringRacingStatusResponseDoesNotResurrectTheJob
  XCTAssertTrue failed - The cancelled job was saved back:
    [… status: LadleCore.ImportStatus.parsing …
       remoteJobID: Optional("017C662A-…") …]
testCancelWhileRequestFailsInFlightDoesNotResurrectTheJobAsFailed
  XCTAssertTrue failed - The cancelled job was saved back:
    [… status: ….failed(….networkUnavailable) …]
testTaskTeardownDuringNetworkCallLeavesJobParsingInsteadOfFailed
  XCTAssertEqual failed: ("Optional(….failed(….networkUnavailable))")
    is not equal to ("Optional(LadleCore.ImportStatus.parsing)")
  XCTAssertEqual failed: ("failed(jobID: 2A9F4C18-…,
    reason: ….networkUnavailable)") is not equal to ("idle")
testResumeWhileForegroundImportPollsLeavesItsOperationAndStateAlone
  XCTAssertTrue failed - resumePendingImports blocked on the foreground
    import instead of skipping it
  XCTAssertEqual failed: ("Optional(….parsing)") is not equal to
    ("Optional(….ready)")
testResumeDoesNotSwapWhichRecipeTheSheetReportsCompleted
  XCTAssertEqual failed: ("Optional(….importJob(4D4A1A02-…))")   [job B]
    is not equal to ("Optional(….importJob(F171FB88-…))")        [job A]
  XCTAssertEqual failed: ("completed(recipeID: F7A4108F-…)")     [recipe B]
    is not equal to ("completed(recipeID: 7BBFC599-…)")          [recipe A]
testServerReportedCancellationRemovesJobAndReadsAsCancelled
  XCTAssertTrue failed - A remotely cancelled job must leave the Inbox
  XCTAssertNotEqual failed: ("persistenceFailed") is equal to
    ("persistenceFailed")
testCancelBeforeRemoteJobAssignedStaysCancelledAndSkipsRemoteCancel
  XCTAssertTrue failed - The cancelled job was saved back:
    [… status: ….failed(….networkUnavailable) … remoteJobID: nil …]
  XCTAssertEqual failed: ("failed(jobID: 0CABD846-…, …)") is not equal
    to ("idle")
testCancellingACompletedImportRemovesTheJobKeepsTheRecipeAndSkipsRemoteCancel
  XCTAssertEqual failed: ("1") is not equal to ("0") - A terminal remote
    job must not receive a cancel request
testCancellingWhileOfflineStillCancelsLocally
  XCTAssertEqual failed: ("persistenceFailed") is not equal to ("idle")
```

The seam test was strengthened after the fix to pin the new presentation
(`state == .cancelled(jobID:)`, `operationFailure == nil`) — the case did not
exist to assert against before it.

`testSecondCancelOfTheSameJobIsANoOp` passed before the fix too
(`deleteImportJob` is a no-op on a missing row in both repositories); it is a
regression guard for the double-cancel path, not red-green evidence.

Atypical states covered: cancelling a job that already completed; cancelling
before a remote job ID exists; cancelling while offline;
`resumePendingImports()` running concurrently with a foreground import (the
backgrounded-and-reopened flow); two cancels of the same job; a
server-reported cancellation mid-poll; the pre-existing
`testCancellationStopsPollingAndLeavesDurableJobParsing` and
`testConfirmedCancellationTerminatesRemoteAndRemovesDurableJob` still pin the
teardown-keeps-the-row and confirmed-cancel-removes-it contracts.

```text
swift test --package-path Packages/LadleCore
  -> 46 tests in 9 suites passed
xcodebuild test -project Ladle.xcodeproj -scheme Ladle \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5'
  -> LadleTests:   274 executed, 1 skipped, 0 failures
  -> LadleUITests:  21 executed, 0 failures
```

The new cancelled presentation was also exercised end-to-end in the demo
simulator (seeded `-ui-testing` launch, `https://youtu.be/cancelled-elsewhere`
through AddRecipeSheet): the sheet shows "Import cancelled" with a working
"Add another recipe" reset, and no job row remains in the Inbox.

Known limitation, recorded deliberately: a cancel that lands while the
initial submit POST is still in flight cannot cancel the remote job the
server may have just created — the app never learned its ID. The row is gone
locally; the orphaned remote job ends server-side, and an idempotent
resubmission of the same job ID would surface as `cancelled`, which the app
now handles.

## Finding #28 — deleting a recipe during its first upload brought it back

### The defect

`deleteRecipe` hard-deletes any row whose `serverRevision` is still 0 —
right when nothing was ever pushed, but the recipe's first PUT can be in
flight at that moment. `performSync` snapshots `pendingRecipeMutations()`
and suspends on the network with the MainActor free, so the user can delete
the recipe mid-upload; the row died with no tombstone, and when the PUT
response landed the repository had no memory that the recipe was deleted.
Finding #7's fix had already stopped `markUpsertSynced` from re-inserting
the server's copy, but its row-is-gone branch was left a deliberate no-op —
so the pull phase of the same sync run met the upload's own change row with
no stored row to match it, took the insert branch, and resurrected the
recipe anyway. The recipe the user deleted reappeared in the library, fully
synced, and its server copy survived to sync to every other device.

### The fix

The flagged line — the hard delete at `serverRevision == 0` — is
deliberately unchanged. Tombstoning never-pushed rows instead would either
wedge sync (the DELETE route requires `baseRevision >= 1`, so a base-0
delete draws a 422 the push loop cannot classify) or leave immortal
invisible rows when no upload was in flight. The acknowledgement is the
first moment this device holds a valid base revision for the recipe, so the
fix lands there: `markUpsertSynced`'s row-is-gone branch now inserts a
tombstoned row at the revision the server just assigned, with a pending
`.delete` — the next sync removes the copy the push created, and
`markDeleteSynced` then drops the row for good.

That alone would have traded resurrection for a phantom conflict: the same
run's pull still delivers the upload's own change row, and `applySyncPage`
checked "does this row have a pending mutation?" before "is this change
news?". The echo — revision equal to the row's own `serverRevision` —
landed in the conflict branch of the freshly tombstoned row. The staleness
guard now runs first: a change whose revision the row already incorporates
is skipped no matter what is pending. Real conflicts always carry a
revision above the row's base, so none are lost — and a replayed page can
no longer re-create an already-resolved conflict either.

`deleteRecipe` on a row with nothing pending and `serverRevision == 0`
(seeded and demo rows) still hard-deletes with nothing queued, as before.

### Verification

Both halves have their own red.
`testDeletingARecipeMidFirstUploadQueuesTheServerSideDelete` (save, delete
mid-flight, acknowledge the PUT) — red before the fix:

```text
XCTAssertEqual failed: ("[]") is not equal to
  ("[Ladle.PendingRecipeMutation.delete(recipeID: 74B93D6E-…, baseRevision: 1)]")
```

`testFirstUploadEchoDoesNotConflictWithTheQueuedServerDelete` continues the
scenario into the pull. Red before any fix — the deleted recipe is back:

```text
XCTAssertNil failed: "Recipe(id: 0EDCD880-…, title: "One-Pot Lemon Orzo", …)"
XCTAssertEqual failed: ("[]") is not equal to
  ("[Ladle.PendingRecipeMutation.delete(recipeID: 0EDCD880-…, baseRevision: 1)]")
```

and red again with only the acknowledgement half applied — the phantom
conflict the guard reorder exists to prevent
(`syncConflictCount`, SwiftDataRecipeRepositoryTests.swift:457):

```text
XCTAssertEqual failed: ("1") is not equal to ("0")
```

`testDeletingANeverUploadedRecipeQueuesNothing` pins the untouched plain
path: created and deleted before any sync, the store ends truly empty —
zero rows, nothing pending, so no unpushable base-0 delete can ever be
queued.

Atypical states covered: deleting a never-synced (`serverRevision == 0`)
recipe while its first upload is in flight; the same deletion with no
upload in flight (nothing queued, no lingering row); the pull echo of the
device's own push over the queued tombstone; the empty-store end state
after create-then-delete offline.

Green: `-only-testing:LadleTests/SwiftDataRecipeRepositoryTests` at 21
executed, 0 failures; full `-only-testing:LadleTests` at 277 executed, 1
skipped, 0 failures.

Known residual, recorded deliberately: if the PUT commits server-side but
its response never arrives, the acknowledgement never runs — the local row
is already gone, and the next pull re-inserts the recipe. Closing that
window needs the client to queue deletes it cannot yet base-revision, i.e.
a contract change (the DELETE route rejects `baseRevision < 1`). Out of
scope here; that window queued nothing before this fix either.

## Finding #27 — a server-side delete wore an edit's clothing

### The defect

When a sync page carried a `.delete` change for a recipe with a pending
local mutation, `applySyncPage`'s conflict branch only advanced
`conflictRemoteRevision` — a delete change carries no recipe, so a
`conflictRemotePayload` stored earlier (by the push's 409 handling, or by
a preceding upsert change in the same page) survived, stale. The review
card then read the non-nil payload as "Changed on another device" with a
friendly "Use Other Version" button, for a recipe the server had deleted.
Accepting it decoded the stale payload, applied it, and stamped the row
with the delete's revision and no pending mutation: a recipe the server
deleted came back into the library at a revision the server will never
re-send — stranded on this device permanently, since the cursor was
already past the delete row. The correct "Deleted on another device" /
"Remove Local Copy" presentation existed in `SyncConflictPresentation`
but was unreachable through production code.

### The fix

The conflict branch is now change-kind-aware. An upsert change stores the
remote copy as before; a delete change clears `conflictRemotePayload` and
advances the revision, so the conflict presents as the deletion it is and
"accept remote" removes the local copy instead of resurrecting a ghost.

One delete arrival needs no review at all: when the local row is itself a
tombstone, both devices deleted the same recipe. The branch now removes
the row outright — nothing to review, nothing left to push. Without this,
the no-op "conflict" would offer Keep My Version, whose re-pushed DELETE
the server must 409 against the already-deleted row, re-preserving the
conflict forever.

The old `testAcceptingRemoteDeletionConflictRemovesLocalRecipe` had to
poke `conflictRemotePayload = nil` into the model by hand because no
production path produced it; it now reaches the same state through
`applySyncPage` alone.

### Verification

`testRemoteDeleteChangeConvertsAStoredEditConflictToADeleteConflict`
plays the finding's trace: a pending local edit, the push's preserved
revision-5 conflict, a pull page carrying the other device's revision-5
edit and revision-6 delete, then "accept remote". Red before the fix (on
top of #28's commit) — the conflict still presents the stale revision-5
copy, and accepting it resurrects the recipe:

```text
XCTAssertNil failed: "Recipe(id: ABC7DDAF-…, title: "Server Title", …)"
  // the conflict's remote side
XCTAssertNil failed: "Recipe(id: ABC7DDAF-…, title: "Server Title", …)"
  // fetchRecipe after accept-remote
XCTAssertTrue failed   // fetchRecipes() is not empty
```

`testMatchingLocalAndRemoteDeletesResolveWithoutReview` — red before the
fix, a review card and a doomed pending delete for a recipe both sides
already deleted:

```text
XCTAssertEqual failed: ("1") is not equal to ("0")   // syncConflictCount
XCTAssertTrue failed   // the delete push still pending
```

Atypical states covered: a delete change arriving atop a stored edit
conflict; a delete change arriving for a pending edit with no stored
conflict (the rewritten accept-remote test); accept-remote on a
remote-deleted recipe; both sides deleting the same recipe; a delete
change for a recipe that does not exist locally; an empty sync page over
an empty store and over a stored conflict
(`testEmptyAndUnknownRecipeSyncChangesAreHarmless`).

Green: `-only-testing:LadleTests/SwiftDataRecipeRepositoryTests` at 24
executed, 0 failures; full `-only-testing:LadleTests` at 280 executed, 1
skipped, 0 failures. `swift test --package-path Packages/LadleCore` (not
touched by either finding) still passes at 46 tests in 9 suites.

Known residual, recorded deliberately: the 409 a push draws for a
server-deleted recipe carries the deleted recipe's DTO as `currentRecipe`
with no deleted marker, so `preserveConflict` stores a non-nil payload
and the mislabel can reappear through the push path alone. That is
reachable if the user resolves a correctly-labeled delete conflict with
"Keep My Version": the re-pushed upsert 409s against the deleted row
forever, because the server cannot resurrect a soft-deleted recipe. Every
pull-side arrival of the delete now corrects the label, but closing the
push path needs the sync-conflict contract to say "deleted" — a backend
plus LadleCore change outside this finding.

## Finding #26 — scrolling a focus-mode step changed the step

### The defect

`FocusModeView` attaches a `DragGesture(minimumDistance: 44)` to the whole
screen with `.simultaneousGesture`, and its `onEnded` looked only at
`translation.width` against ±44. `minimumDistance` is a Euclidean threshold,
so a normal one-handed thumb scroll of long step content — ~200pt of
vertical travel with ~50pt of sideways arc — began the gesture on vertical
travel alone and then passed the width check on the drift. Mid-recipe that
silently advanced the cook to the next step; on the last step, `advance()`
falls through to `exitFocusMode()`, so the same scroll threw the cook out of
Focus Mode entirely. A rightward-arcing scroll fired `movePrevious()`
symmetrically. Long steps are exactly the ones that need scrolling — at
accessibility Dynamic Type sizes the 36pt step text does not shrink at all
(`minimumScaleFactor` is disabled), so the overflow case is the common case.

### The fix

The classification is extracted into `FocusModeSwipe` (same file), and a
drag now counts as a swipe only when it is *predominantly horizontal* —
`abs(width) > abs(height)` — as well as travelling more than 44pt on the
horizontal axis. A vertically-dominated drag classifies as nil and changes
nothing, whatever its sideways drift. The gesture stays a
`.simultaneousGesture` with the same 44pt activation distance, so the
ScrollView's own pan is never blocked or delayed: scrolling keeps scrolling,
and a deliberate sideways swipe (dominant horizontal travel) still moves
between steps or, on the last step, exits Focus Mode.

### Verification

`LadleTests/FocusModeSwipeTests` drives the classifier with the reviewer's
own translations. The extraction was landed first with the old width-only
logic verbatim, so the new tests ran red against the shipping behavior:

```text
FocusModeSwipeTests.swift:13: error: -[LadleTests.FocusModeSwipeTests
testVerticalScrollWithLeftwardDriftIsNotASwipe] : XCTAssertNil failed:
"nextStep" - A vertical scroll drifting left must not read as a next-step
swipe
FocusModeSwipeTests.swift:22: error: -[LadleTests.FocusModeSwipeTests
testVerticalScrollWithRightwardDriftIsNotASwipe] : XCTAssertNil failed:
"previousStep" - A vertical scroll drifting right must not read as a
previous-step swipe
FocusModeSwipeTests.swift:31: error: -[LadleTests.FocusModeSwipeTests
testPerfectDiagonalIsNotASwipe] : XCTAssertNil failed: "nextStep" - An
ambiguous 45-degree drag must not change the step
```

The four companion tests — deliberate left/right swipes still classify, and
the 44pt boundary is exclusive on both sides — passed against the extracted
old logic too, proving the extraction changed nothing before the fix did.
After the dominance guard, `-only-testing:LadleTests/FocusModeSwipeTests`
is 7/7 (`** TEST SUCCEEDED **`), and
`-only-testing:LadleTests/CookingViewModelTests` still passes to sweep the
step-navigation neighbors (clamping at the first/last step, mode switching,
single-step recipes are all view-model behavior this change does not touch —
the classifier returning nil is what now protects them from accidental
drags; a genuine horizontal swipe behaves exactly as before).

## Finding #12 — a malformed caption URL crashed the import instead of being skipped

### The defect

`caption_links` accepted `https://evil.example.com:abc/recipe` because
`_host_of` read only `urlsplit(...).hostname`, and `urlsplit` parses the port
lazily — nothing ever touched it. The first statement of
`PinnedHTTPClient.get` is `httpx.URL(url)`, and httpx is stricter: the
garbage port raises `httpx.InvalidURL`, which is a plain `Exception` —
not an `httpx.HTTPError`, not an `OSError`, not `UnsafeNetworkTarget`. No
handler between the fetcher and the Celery worker names it, so one bad link
in an attacker-controlled caption dead-lettered the entire import instead of
being skipped like every other unsafe link. The same escape reached
`MediaAudioSource._download` (provider-supplied media URLs go through the
same client), and both pinned clients re-parse redirect targets with
`httpx.URL` after only `urlsplit`-based validation, so a hostile `Location`
header had a rarer route to the same crash — httpx also enforces limits
`urlsplit` does not, such as its 65,535-character total-length cap, which a
near-limit relative `location` can exceed after `urljoin`.

### The fix

Two parse boundaries, no catch-sites sprinkled:

- `_host_of` now forces the port parse (`_ = parts.port`) inside its
  existing `try`, so a caption URL with garbage where the port belongs is
  refused as `UnsafeURL` while links are being collected — that one link is
  dropped and the caption's other links still fetch.
- `PinnedHTTPClient` converts `httpx.InvalidURL` into `UnsafeNetworkTarget`
  at both places it parses: the entry parse in `get`, and the per-address
  `copy_with` (now the shared `_pinned_url` helper, also used by
  `PinnedRedirectResolver`). `UnsafeNetworkTarget` is the refusal every
  caller already handles: `SafeLinkFetcher` re-raises it as `UnsafeURL` and
  `_fetch_all` skips the link; `MediaAudioSource._download` logs and returns
  `None`.

### Verification

`tests/unit/acquisition/test_free_links.py` gained five tests and
`tests/unit/acquisition/test_media_ssrf.py` one. Red before the fix:

```text
FAILED test_free_links.py::test_caption_links_drop_urls_with_malformed_ports
  AssertionError: assert ['https://evi...e.com/recipe'] == ['https://goo...e.com/recipe']
FAILED test_free_links.py::test_malformed_port_is_refused_like_any_other_unsafe_target
  httpx.InvalidURL: Invalid port: 'abc'
FAILED test_media_ssrf.py::test_malformed_media_url_is_skipped_not_fatal
  httpx.InvalidURL: Invalid port: 'abc'
    (raised from ladle/infrastructure/dns.py:177, in get)
3 failed, 4 passed
```

Atypical states covered alongside the repro: a URL whose explicit port is
valid but non-443 is still *collected* (`:8443` — refusing it is fetch-time
validation's job, pinned by test so this fix cannot over-reject); a
scheme-less URL is refused; a host that resolves to zero DNS addresses is
refused; and a 70,000-character redirect `Location` is refused as
`UnsafeURL` — that path was already safe because httpx raises
`RemoteProtocolError` (an `HTTPError`) while processing the redirect
response, and the new test pins it against regression.

```text
uv run pytest -q tests/unit/acquisition/test_free_links.py \
    tests/unit/acquisition/test_media_ssrf.py       -> 33 passed
uv run ruff check ladle tests alembic               -> All checks passed
uv run mypy --strict ladle                          -> clean
```

**Follow-up, same finding.** Probing the redirect corridor end-to-end after
the first commit showed one `InvalidURL` route still open: httpx joins a
*relative* `Location` itself inside `send()`, and the joined URL can exceed
its 65,535-character cap even though the location alone does not. That
surfaces as a bare `httpx.InvalidURL` raised *by* `client.send` — not an
`HTTPError`, so it sailed past both pinned clients' send handlers. Red:

```text
FAILED test_free_links.py::test_redirect_to_an_overlong_relative_location_is_refused
  httpx.InvalidURL: URL too long
    (raised from httpx/_urlparse.py:219 via request.url.join inside client.send)
```

Both `_request_pinned` methods now convert `httpx.InvalidURL` from the send
into the same `UnsafeNetworkTarget` refusal, raised immediately rather than
retried per address — a URL httpx cannot represent is invalid for every
address. 38 links tests green after.

## Finding #13 — one hostile page pinned the import worker for half an hour

### The defect

`_readable` ran `_SCRIPTISH` — a lazy backreference regex,
`<(script|style|…)[^>]*>.*?</\1>` — over response bodies as large as the
2 MB fetch cap, and creator caption links resolve to servers the creator
controls. On a body of opening tags that never close, the lazy `.*?` expands
to end-of-string once per opening tag: quadratic. Measured scaling on the
shipped regex — 2,000 tags 0.06 s, 4,000 tags 0.29 s — extrapolates to
roughly 48 minutes at the cap (400,000 tags), all inside one uninterruptible
`re.sub` C call, so even Celery's soft-limit SIGALRM cannot fire until the
hard limit SIGKILLs the child. The tag stripper `_TAG` (`<[^>]+>`) had the
same shape by a different payload: with no `>` anywhere, it re-scans to
end-of-string from every `<`. One posted video with one caption link was
enough to stall the single-threaded worker and everything queued behind it.

### The fix

`_readable` now uses two linear scanners instead of the two vulnerable
regexes, bounding the work before the attacker-controlled body reaches any
backtracking engine:

- `_without_scriptish` finds each opening tag with a regex that cannot
  backtrack across tags, then finds its literal close with a forward search.
  The scan position only moves forward, and a tag name with no close ahead
  is remembered — each of the six names costs at most one failed search over
  the remainder, and an unmatched opening tag is left for the tag stripper
  exactly as the old regex left it.
- `_without_tags` replaces each complete `<...>` region using plain
  `str.find`, again strictly forward.

At the 2 MB cap the worst measured inputs now take 0.23 s (400,000 unclosed
`<svg>`), 0.06 s (a megabyte of `<a` with no `>`), and 0.05 s (111,111
closed `<script>` pairs). A 3,000-case randomized differential against the
old pipeline shows byte-identical output except that a literal `<>` is now
stripped like any other tag (the old `[^>]+` required one character);
every behavioral case is also pinned by named tests: unclosed script keeps
the text after it, closes match case-insensitively, scanning resumes after
a closed block, and an empty body stays empty.

### Verification

Red on the shipped regexes — both timing tests, sized at 100–150 KB so the
red run itself terminates:

```text
>       assert time.perf_counter() - started < 1.0
E       assert (557307.652135166 - 557301.993815208) < 1.0   # 5.66 s
FAILED test_free_links.py::test_unclosed_scriptish_soup_is_processed_in_linear_time
>       assert time.perf_counter() - started < 1.0
E       assert (557311.530182916 - 557307.683301) < 1.0      # 3.85 s
FAILED test_free_links.py::test_unclosed_angle_bracket_soup_is_processed_in_linear_time
2 failed, 5 passed, 30 deselected in 9.77s
```

The 5 passes are the semantics pins, written against the old behavior first
so the swap provably changed speed and not meaning. Atypical states: empty
body; body exactly at a fetcher byte cap kept, one byte over refused as
`UnsafeURL`; unclosed blocks; case-crossed close tags; markup soup with no
closing `>` at all.

```text
uv run pytest -q tests/unit/acquisition/test_free_links.py  -> 37 passed in 0.27s
uv run ruff check ladle tests alembic                       -> All checks passed
uv run mypy --strict ladle                                  -> clean
```

## Finding #11 — a reversed Whisper timestamp killed the whole import

### The defect

`_transcript` built `TextEvidence` straight from Whisper's segment list.
`_seconds` accepts any non-negative number, so a segment of
`{"start": 12.0, "end": 3.0}` sailed through both calls and then hit
`TextEvidence.validate_time_range`, whose `ValueError` pydantic wraps as a
`ValidationError`. `WhisperTranscriber.transcribe` catches only
`AcquisitionError`, so the ValidationError escaped it — leaving the ledger
attempt started in `transcribe` permanently `running`, holding its usage
reservation — then escaped the provider chain and the orchestrator's handler
tuple, and dead-lettered the job. The word path had the same hole one level
up: `_words` filters each word's own `end < start`, but words arriving out
of chronological order make `_segments_from_words` emit a segment whose
start comes from the first word and end from the last — reversed across
words, same uncaught ValidationError. The sibling providers (supadata,
soscripted) convert this exact construction failure into a recoverable
error, which marks the omission as an oversight; Whisper is the last rung,
so here the right degradation is finer still: the text is fine, only the
claimed moment is garbage.

### The fix

Both windows are validated at the parse boundary, before any constructor
that assumes well-formed input:

- The segment loop reads `start`/`end` once; a reversed pair becomes
  `None`/`None` — the same "no time claimed" shape the flat-text fallback
  already uses — so the words survive without inventing a moment for them.
- `_words` now sorts by `(start, end)`. A transcript is temporal, so
  out-of-order words read back in time order; with sorted starts, every
  regrouped segment's end (its last word's end) is provably at or after its
  start (its first word's start), for any grouping the pause/length rules
  choose. No exception path was added, because after these two bounds every
  remaining `TextEvidence` field is already guaranteed by construction.

### Verification

Red on the shipped code — both constructions raise the exact escape the
finding describes:

```text
E           pydantic_core._pydantic_core.ValidationError: 1 validation error for TextEvidence
E             Value error, evidence end must not precede its start [type=value_error,
E               input_value={'text': 'stir the pot', ...-v3', 'generated': True}, ...]
ladle/acquisition/audio.py:453: ValidationError
E       pydantic_core._pydantic_core.ValidationError: 1 validation error for TextEvidence
E         Value error, evidence end must not precede its start [type=value_error,
E           input_value={'text': 'later earlier',...-v3', 'generated': True}, ...]
ladle/acquisition/audio.py:402: ValidationError
FAILED test_audio.py::test_reversed_segment_window_degrades_to_untimed_evidence
FAILED test_audio.py::test_out_of_order_word_timings_cannot_produce_a_reversed_window
2 failed, 1 passed
```

The single pass in the red run is the boundary pin: a zero-length window
(`start == end`) is legal evidence and stays kept, before and after.
Atypical states: reversed segment window (text kept, window dropped);
out-of-order word timings (reordered, window monotonic); zero-length
window; every existing shape — words-win-over-segments, timing-less words,
flat-text-only, empty transcript — still passes unchanged.

```text
uv run pytest -q tests/unit/acquisition/test_audio.py  -> 21 passed in 1.26s
uv run ruff check ladle tests alembic                  -> All checks passed
uv run mypy --strict ladle                             -> clean
```

## Finding #17 — thirteen characters of model output allocated a gigabyte

### The defect

`_apply_patch` parses model-supplied patch values with `_decimal`, which
accepted any finite `Decimal` — and `Decimal("1E+1000000000")` is finite.
The very next step for `servings`, `normalized_quantity` and
`metric_amount` is `format(parsed_decimal, "f")`, which materializes the
full fixed-point string: a 1,000,000,001-character (~1 GB) allocation from a
13-character value, followed by a second one in `_value_is_cited`'s
`str(value).casefold()`. Both run *before* the citation check that would
have rejected the patch, so the allocation was unconditional once the field
was flagged. A huge negative exponent expands the same way as
`0.000…1`. Reachable through prompt injection steering the verifier, or —
with no model compliance at all — any upstream OpenRouter routes to
returning that JSON, since `VerificationPatch.value` carries no bound. The
worker OOMs or thrashes instead of simply refusing the patch.

### The fix

`_decimal` now bounds what it accepts before anything can expand it, at the
one boundary every consuming path shares (`servings`, ingredient
quantities, `_stated_servings`, `_fraction`, `_reported_cost`):

- input longer than 64 characters is refused (the digit-heavy variant of
  the same amplification);
- a finite result with `abs(adjusted()) > 12` is refused — `adjusted()`
  reads the stored exponent without expansion, and nothing in a recipe
  (or a provider cost) leaves the 1E-12..1E+12 band.

No call site changed: rejected values flow through the existing
`_decimal(...) is None` branches, so the patch is refused and the field
stays an uncertainty for review, exactly like any other unusable value.

### Verification

The observable defect is a transient allocation — the patch was ultimately
*rejected* both before and after the fix (by the citation check, after the
gigabyte was already allocated) — so a black-box red would either prove
nothing or have to allocate gigabytes in CI. The red therefore sits at the
exact root cause, `_decimal` accepting the value:

```text
>       assert _decimal(value) is None
E       AssertionError: assert Decimal('99999999999999999999999999999999999999999999999999999999999999999') is None
FAILED test_verification.py::test_untrusted_decimals_outside_the_recipe_band_are_refused[1E+1000000000]
FAILED test_verification.py::test_untrusted_decimals_outside_the_recipe_band_are_refused[1E-1000000000]
FAILED test_verification.py::test_untrusted_decimals_outside_the_recipe_band_are_refused[1E+13]
FAILED test_verification.py::test_untrusted_decimals_outside_the_recipe_band_are_refused[1E-13]
FAILED test_verification.py::test_untrusted_decimals_outside_the_recipe_band_are_refused[9999…(65 digits)]
5 failed, 12 passed
```

The 12 passes pin what already held: `NaN`, `sNaN`, `±Infinity` were
refused before, and every recipe-scale value — `"4"`, `"2.5"`, `15`,
`" 250 "`, `"0"`, `"-3"`, and both band edges `"1E+12"`/`"1E-12"` — parses
identically after.
`test_model_supplied_exponent_bomb_is_rejected_without_expansion` then
drives the full `verify()` path with the finding's exact payload
(`{"fieldPath": "servings", "value": "1E+1000000000"}` against "Serves 4."
evidence) and asserts the patch is refused, servings stays flagged for
review, and the call returns in bounded time with no expansion.

```text
uv run pytest -q tests/unit/extraction/  -> 104 passed in 0.95s
uv run ruff check ladle tests alembic    -> All checks passed
uv run mypy --strict ladle               -> clean
```

## Finding #18 — the reservation sweep took locks backwards and deadlocked

### The defect

Every path that completes, fails, retries, or cancels an import takes the
`import_jobs` row lock first and the `recipe_slot_reservations` row lock
second: `ExtractionCacheService.complete_shared` locks the batch of parsing
jobs and then `ReservationService.consume` locks each job's reservation;
`ImportTransitionService.fail`, `ImportRetryService.retry` and
`ImportCancellationService.cancel` do the same for a single job.

`ImportMaintenanceService.release_expired_reservations` did the opposite. Its
join query used `.with_for_update(of=RecipeSlotReservation)` — locking only
the reservation rows — and then mutated the joined `ImportJob` objects, whose
`UPDATE import_jobs` was emitted later, at the next autoflush or at commit.
A worker finishing (or a user cancelling) a job the sweep had matched would
lock `import_jobs` and block on the sweep's reservation lock, while the
sweep's deferred update blocked on that job lock: a cycle Postgres resolves
by aborting one side with `deadlock detected` (SQLSTATE 40P01). When the
sweep loses, the whole beat transaction rolls back — reservation release,
`recover_abandoned`'s stuck-job requeue, and operational-metrics capture are
all lost for that 30-second interval, and `dispatch_pending` never runs.

### The fix

`release_expired_reservations` now scans for candidates lock-free (ordered
by `ImportJob.created_at, ImportJob.id` — the same global order
`complete_shared` uses for its batch lock), then locks each pair in the
shared order: the import-job row first, the reservation second. Because the
candidate scan is unlocked, each pair is re-checked once both locks are held
(`state == "reserved"`, still expired, row still present); a reservation
consumed or reactivated in the window is skipped. The job mutation now
happens on a row the sweep already holds, so the deferred-update cycle
cannot form. Behavior is otherwise byte-for-byte: terminal jobs release,
stale parsing jobs release and fail with `abandonedImport`, completed jobs
with a recipe mark their reservation consumed, and the released count
excludes consumed slots.

A sweep can never race a *fresh* submission: a just-created reservation has
`expires_at = now + lifetime`, so the candidate predicate cannot select it.
The reachable race is with completion/cancellation of an already-expired
job, which is exactly what the new test drives.

Sibling hazard noted, not fixed here: `ImportTransitionService.fail` locks
its shared-follower batch with no `ORDER BY`, so two concurrent `fail`
batches over the same source video are not globally ordered against
`complete_shared`. Pre-existing, independent of the sweep, and left alone.

### Verification

`test_sweep_does_not_deadlock_with_a_concurrent_cancellation` seeds one
stale parsing job with an expired reservation, runs the sweep in one
transaction that holds its locks for two seconds after doing its work, and
cancels the same job from a second thread the moment the sweep's work is
done — the beat-vs-user interleaving from the finding. Red, on the old code
(the cancellation locks the job and blocks on the sweep's reservation lock;
the sweep's commit then flushes `UPDATE import_jobs` into the cycle):

```text
E           sqlalchemy.exc.OperationalError: (psycopg.errors.DeadlockDetected) deadlock detected
E           DETAIL:  Process 78 waits for ShareLock on transaction 736; blocked by process 79.
E           Process 79 waits for ShareLock on transaction 735; blocked by process 78.
E           CONTEXT:  while updating tuple (0,1) in relation "import_jobs"
E           [SQL: UPDATE import_jobs SET status=%(status)s::VARCHAR, stage=%(stage)s::VARCHAR, ...]
FAILED tests/integration/imports/test_maintenance.py::test_sweep_does_not_deadlock_with_a_concurrent_cancellation
1 failed, 2 passed in 6.73s
```

Green: the cancellation serializes behind the job lock instead, finds the
job already failed by the sweep, and raises
`ImportCancellationUnavailable`; the sweep commits — released reservation,
failed job, nothing aborted. Atypical states pinned alongside it:
`test_sweep_with_nothing_to_reclaim_takes_no_locks_and_releases_nothing`
(zero-row sweep returns 0), and
`test_sweep_marks_completed_jobs_consumed_and_skips_consumed_reservations`
(a ready job with its recipe keeps the slot as `consumed` — a branch no
prior test covered — and an already-consumed reservation is untouched).
The pre-existing terminal/stale/fresh matrix passes unchanged.

```text
uv run pytest -q tests/integration/imports/test_maintenance.py  -> 5 passed in 6.12s
uv run ruff check ladle tests alembic                           -> All checks passed
uv run mypy --strict ladle                                      -> clean
```

## Finding #19 — a rolled-back import stranded its thumbnail in the bucket forever

### The defect

`ImportOrchestrator.process` PUTs the downloaded thumbnail bytes into object
storage (`thumbnails/<source_video_id>/<uuid4>.jpg`) *before* opening the
completion transaction. If that transaction rolled back — the user deleted
the target recipe mid-re-import (`ValueError("current recipe is
unavailable")`), a stalled heartbeat raised `ClaimLost` (once per Celery
retry, each retry storing a fresh key) — or the key was silently discarded
because the job had been cancelled while extraction ran (the
`ALREADY_COMPLETED` early return), then no `ExtractionCache` row and no
`RecipeImage` row ever referenced the key. Every cleanup path in the
codebase enumerates database rows: `delete_unreferenced_thumbnails` walks
`ExtractionCache`, the retention sweep and account deletion enqueue
DB-held keys into `ObjectDeletionQueue`, and the bucket lifecycle policy
expires only `temporary/` and noncurrent versions. Nothing can ever find a
current-version object under `thumbnails/` with no row, so the orphan
stayed in the bucket permanently.

### The fix

Schedule-then-cancel, using the deletion queue the reaper already drains:

- Immediately after `store()` returns a key, the orchestrator commits (in
  its own short transaction) an `ObjectDeletionQueue` row for the key with
  `reason="unreferencedThumbnail"` and `available_at = now + 1 hour`
  (`_schedule_thumbnail_discard`). The grace keeps a mid-flight completion —
  which follows the upload within seconds — out of the reaper's reach.
- Inside the completion transaction, after `complete_private_for_job` /
  `complete_shared`, `_cancel_thumbnail_discard` deletes that queue row —
  but only when an `ExtractionCache` or `RecipeImage` row now references the
  key, so the withdrawal commits atomically with the reference.

Every failure shape then needs no code of its own: a rollback rolls back
the withdrawal too; the `ALREADY_COMPLETED` return never reaches it; a
worker crash between upload and completion leaves the schedule committed;
and `complete_shared`'s silently-dropped-key branch (entry already had a
thumbnail) fails the referenced-check, so the fresh upload is reaped rather
than the withdrawal firing. The already-wired `ObjectDeletionProcessor`
beat task deletes the object once the grace passes.

### Verification

`tests/integration/imports/test_thumbnail_discard.py`, three tests. Red on
the unfixed code — the finding's two leak shapes, byte for byte:

```text
>           assert key in queued, "the orphaned upload must be queued for deletion"
E           AssertionError: the orphaned upload must be queued for deletion
E           assert 'thumbnails/eaf54e21-5f18-4731-a14d-be1664490b40/0.jpg' in {}
FAILED tests/integration/imports/test_thumbnail_discard.py::test_rolled_back_completion_queues_the_uploaded_thumbnail_for_deletion
FAILED tests/integration/imports/test_thumbnail_discard.py::test_job_finished_elsewhere_queues_the_discarded_thumbnail_for_deletion
2 failed, 1 passed in 3.97s
```

The first drives a real re-import whose target recipe is soft-deleted
mid-extraction (rollback path), then closes the loop end to end: the queue
row is pinned at `available_at == now + 1h`, an early reaper pass deletes
nothing, and a pass after the grace removes the object from the (fake)
bucket. The second cancels the job mid-extraction — the no-exception
discard path — and asserts the key is queued. The third is the green-side
guard for the atypical inverse: a successful completion leaves the key
referenced by both the cache entry and a `RecipeImage`, the queue empty,
and a late reaper pass deleting nothing — scheduling deletions for every
upload must never cost a live thumbnail.

```text
uv run pytest -q tests/integration/imports/test_thumbnail_discard.py               -> 3 passed in 4.18s
uv run pytest -q tests/e2e/test_fake_import_round_trip.py \
    tests/integration/imports/test_retry_reparse.py tests/integration/cache        -> 21 passed in 12.60s
uv run ruff check ladle tests alembic                                              -> All checks passed
uv run mypy --strict ladle                                                         -> clean
```

## Finding #15 — one account could hoard Apple identities it can never revoke

### The defect

After a first Apple sign-in a user's `kind` is `'apple'`, and
`_claim_identity`'s gate — `guest.kind in {"guest", kind}` — exists so the
same-subject re-sign-in stays idempotent. But a sign-in with a *different*
Apple ID also passes it: `merge()` finds no row for the new subject, takes
the claim branch, and inserts a second `AppleIdentity` row for the same
`user_id` — nothing in the model or migrations 0001–0014 constrains
`apple_identities.user_id`. Account deletion then runs
`select(AppleIdentity).where(user_id == ...)` with no ORDER BY, revokes
whichever row Postgres yields first, and cascade-deletes the rest: the other
Apple grant stays live at Apple after the account is gone (violating the
Sign in with Apple deletion requirement), and *which* grant survives is
nondeterministic. `merge_google` has the identical branch shape, so Google
identities could pile up the same way.

This extends the sign-out work in `b648aed` rather than fighting it: that
commit governs what a *device* may mint after sign-out; this one governs
what an *account* may accumulate while signed in.

### The fix

Three layers, one invariant — at most one provider identity row per user:

- `_claim_identity` (`Backend/ladle/auth/merge.py`) refuses the claim with
  `AccountMergeInvalid` when the locked user already owns an identity row of
  that provider. The check sits after `_lock_users`' `FOR UPDATE`, so
  concurrent claims of two different subjects serialize on the user row and
  exactly one wins. The same-subject path never reaches the claim branch
  and stays idempotent (token refresh included).
- `apple_identities.user_id` and `google_identities.user_id` gain named
  unique constraints in the models — the schema-level backstop.
- Migration `0015_one_identity_per_user` creates the constraints, first
  collapsing any duplicates the bug already produced: the oldest row per
  user is kept (ties broken by subject) — the identity that originally
  claimed the account. A migration cannot call Apple, so the dropped rows'
  grants are discarded unrevoked exactly as the bug would have discarded
  them at deletion; the kept identity still revokes normally. The downgrade
  drops both constraints.

With uniqueness guaranteed, deletion's single-row lookup is exact — no
change needed there.

Follow-up caught by the full-suite gate (`c745cb8`): `DatabaseReadinessProbe`
pins the schema revision the application expects, so adding migration 0015
required moving that pin from `0014` to `0015` — otherwise a deployed API
over the migrated database reports not-ready forever.

### Verification

Red on the unfixed code (`tests/integration/auth/test_merge.py`):

```text
>           pytest.raises(AccountMergeInvalid),
E       Failed: DID NOT RAISE AccountMergeInvalid
>       assert sorted(results, key=str) == sorted(
E       AssertionError: assert [UUID('62949c...a9d243a8b37')] == [UUID('62949c...ergeInvalid'>]
E         At index 1 diff: UUID('62949cb3-0c04-4e2a-9c72-9a9d243a8b37') != <class 'ladle.auth.merge.AccountMergeInvalid'>
FAILED tests/integration/auth/test_merge.py::test_a_user_with_an_apple_identity_cannot_claim_a_second_one
FAILED tests/integration/auth/test_merge.py::test_a_user_with_a_google_identity_cannot_claim_a_second_one
FAILED tests/integration/auth/test_merge.py::test_concurrent_claims_of_two_apple_identities_admit_exactly_one
3 failed, 3 deselected in 3.04s
```

The identity-count states: zero (fresh guest claims fine — pre-existing
first-sign-in test), one (second claim refused; same-subject re-sign-in
still succeeds and rotates the stored token), two-at-once (the concurrent
test: two threads, two subjects, barrier release — exactly one wins, one
`AccountMergeInvalid`, one row; under the old code both won). The
two-rows-already-persisted state is covered where it can still exist — as
pre-0015 data: `test_identity_uniqueness_migration_dedupes_and_enforces_one_per_user`
(green-side only; it cannot run red because the revision did not exist)
seeds duplicate Apple rows with distinct timestamps, duplicate Google rows
with identical timestamps, and a single-identity user at revision 0014,
upgrades, and asserts the oldest/tie-broken row survives, the lone identity
is untouched, a fresh duplicate insert now fails on
`uq_apple_identities_user_id`, and the downgrade re-admits duplicates.
`test_migrated_schema_matches_model_metadata` (`command.check`) pins the
model constraints to the migration's.

Deletion-side atypical states (`tests/api/test_apple_auth.py`): an identity
whose exchange returned no refresh token deletes with zero revocation calls
(`X-Deletion-Status: completed`); a revocation Apple rejects (an expired or
already-revoked grant) blocks deletion with 503, leaves the user and an
audit row `failed`/`AppleTokenRevocationFailed`, and the same idempotency
key retries to 204 once Apple accepts — the token is never discarded while
the grant might be live.

```text
uv run pytest -q tests/integration/auth tests/api/test_apple_auth.py \
    tests/api/test_google_auth.py tests/api/test_guest_auth.py   -> 24 passed in 11.66s
uv run pytest -q tests/integration/test_migrations.py            -> 7 passed in 4.44s
uv run ruff check ladle tests alembic                            -> All checks passed
uv run mypy --strict ladle                                       -> clean
```

## Finding #14 — one slow import submission stalled the whole worker

### The defect

FastAPI runs `async def` endpoints on the event loop and `def` endpoints in
the anyio threadpool. Every route in this app does blocking I/O — sync
SQLAlchemy sessions, sync Redis, sync broker publishes — so they are all
`def`… except `submit_import` and `retry_import`, which were `async def`
solely to `await request.body()` for the App Attest body hash. Everything
else inside them then ran on the event loop: `access_claims` (two blocking
`Session.get`s), `_installation_id` (a third), the rate-limit backend's
synchronous `redis.eval` (no socket timeout configured), the whole
admission transaction, and `dispatch_one`'s `SELECT … FOR UPDATE` plus
synchronous Celery publish. A slow row-lock grant, a hung rate-limit Redis,
or a slow broker parked the loop for the full duration — every other
in-flight request on that uvicorn worker stalled behind it, including
`GET /health/live`, whose failing timeout gets the container restarted and
the other in-flight imports killed with it. `grep -rn "async def"
Backend/ladle/api` confirms these two handlers were the only `async def`
routes in the app (the remaining hits are middleware and error handlers,
which belong on the loop).

### The fix

Match the app's own established pattern instead of inventing one: both
handlers are now `def` — dispatched to the threadpool like every other
route — and the one genuinely asynchronous step moved into a four-line
async dependency, `_request_body`, which awaits `request.body()` on the
loop (that is what the loop is for) and hands the bytes to the handler.
Starlette caches the body on the `Request`, so the dependency and FastAPI's
own Pydantic parse share the same bytes and the App Attest hash stays
byte-exact — the enforced-attestation suite pins that.

### Verification

`tests/api/test_import_route_concurrency.py` wires the app with an
attestation service whose `verify` sleeps 1.5 s — standing in, inside the
handler, for any of the blocking calls above — submits an import on a
worker thread, waits until the request is inside the stalled handler, and
then times `GET /health/live` (a `def` route that answers from the
threadpool in milliseconds when the loop is free). Red, on the `async def`
handlers — the health check inherits the entire stall:

```text
>           assert elapsed < HEALTH_BUDGET_SECONDS, (
E           AssertionError: /health/live took 1.571s while a submission was in flight: the import handler is blocking the event loop
E           assert 1.5706271659582853 < 0.75
FAILED tests/api/test_import_route_concurrency.py::test_a_slow_import_submission_does_not_stall_other_requests
1 failed in 4.69s
```

Green: `/health/live` answers well inside the 0.75 s budget while the
submission is mid-stall, the submission itself still completes (202,
dispatched exactly once), and the same measurement repeated against
`POST /v1/imports/{id}/retry` on a failed job holds too — both converted
handlers, both end-to-end functional while concurrent. The existing
`tests/api` suite plus `tests/integration/auth/test_app_attest.py` (33
tests) pin submission, cancellation, idempotent replay, and the
enforced-attestation body hash unchanged.

```text
uv run pytest -q tests/api/test_import_route_concurrency.py            -> 1 passed in 6.28s
uv run pytest -q tests/api tests/integration/auth/test_app_attest.py   -> 33 passed in 15.66s
uv run ruff check ladle tests alembic                                  -> All checks passed
uv run mypy --strict ladle                                             -> clean
```

## Finding #16 — three recipe child tables scanned on every fetch

### The defect

Every recipe fetch filters `detected_timers` on `recipe_step_id`,
`field_uncertainties` on `recipe_id` and `other_nutrients` on
`nutrition_recipe_id` (`RecipeRepository.to_dto`), and every recipe
update deletes through the same columns (`_delete_graph`). None of the
three columns had an index: `models.py` declared none, migration 0001
created the tables with only a primary key on `id`, and no later
migration added one. Postgres does not index a foreign key's
referencing column on its own, and unlike `recipe_images`,
`ingredients` and `recipe_steps` — whose `recipe_id` leads a unique
constraint — nothing else covers these. Each of those statements was
therefore a sequential scan of a table that is global and grows with
every user's recipes (`detected_timers` at roughly recipes × steps ×
timers), so one user's fetch latency scaled with the size of the whole
corpus, and a 100-item sync page performed 200–300 full scans.

The other child tables were checked for the same omission
(leading-column index coverage of every foreign key, composite keys
included). Covered: `recipe_images.recipe_id`, `ingredients.recipe_id`
and `recipe_steps.recipe_id` by leading-column unique constraints,
`step_ingredients` by its primary key, `nutrition.recipe_id` as the
primary key, `recipes.user_id` by an explicit index. Same omission but
probed only by rarer cascade or maintenance paths, so left for their
own finding rather than silently widening this one:
`field_uncertainties.ingredient_id` and `.step_id` (RI-trigger probes
once per row when `_delete_graph` deletes a recipe's ingredients and
steps), `recipe_changes.recipe_id` (probed when retention pruning or an
account-deletion cascade hard-deletes recipe rows), and the auth/import
graph (`devices.user_id`, `auth_sessions.user_id` and `.device_id`,
`import_jobs`' five references, `extraction_claims.owner_job_id`,
`import_quota_events.import_job_id`, `users.merged_into_user_id`,
`recipes.source_video_id` and `.source_cache_id`,
`provider_attempts.budget_window_started_at`), none of which sits on
the per-fetch path.

### The fix

Named `Index(...)` declarations on the three models —
`ix_detected_timers_recipe_step_id`, `ix_field_uncertainties_recipe_id`,
`ix_other_nutrients_nutrition_recipe_id` — and migration 0016 creating
the same three indexes, with a downgrade that drops them in reverse
order. `test_migrated_schema_matches_model_metadata` (`alembic check`)
holds the models and the migration chain identical, so neither side can
drift from the other. The readiness probe pins the revision the
application expects, so it moves to 0016 with the migration.

### Verification

`tests/integration/test_migrations.py::test_recipe_child_foreign_key_indexes_upgrade_and_downgrade`
migrates an empty database to head, asserts each of the three indexes
exists, then downgrades to 0015 and asserts all three are gone again.
Red, before the fix:

```text
>           assert index in names, f"{table} has no index on its foreign key: {names}"
E           AssertionError: detected_timers has no index on its foreign key: set()
E           assert 'ix_detected_timers_recipe_step_id' in set()
FAILED tests/integration/test_migrations.py::test_recipe_child_foreign_key_indexes_upgrade_and_downgrade
1 failed in 2.38s
```

Green: the new test passes in both directions, and the rest of the
migrations file — schema completeness, model/migration parity
(`alembic check`), constraint enforcement, and every earlier
up/downgrade test — stays green:

```text
uv run pytest -q tests/integration/test_migrations.py  -> 8 passed in 4.98s
uv run ruff check ladle tests alembic                  -> All checks passed
uv run mypy --strict ladle                             -> clean
```

## Finding #23 — one sync page fanned out to hundreds of queries

### The defect

`RecipeSyncService.page` looped over the page's change rows and, for
every row, called `find()` — one SELECT — and then `to_dto()`, which
issued six child-table selects plus a nutrition get and an
`other_nutrients` select: about nine statements per change. A
`limit=100` page therefore ran ~900 sequential statements inside one
request, all on a single pooled connection held for the duration; the
iOS client pages with `limit=100` in a loop until `has_more` is false,
so the initial sync of a 500-recipe library cost ~4,500 statements.
Three of those per-row selects also hit the unindexed columns #16
fixed, so each of them was a sequential scan besides.

### The fix

The page now reads recipes and materialises DTOs in bulk. `find_many()`
fetches every recipe on the page, tombstones included, in one query,
and `to_dtos()` loads each child table once for the whole page with
`IN` over the page's recipe ids, groups the rows in memory, and
assembles per-recipe DTOs through the same code single-recipe reads use
— `to_dto` now delegates to `to_dtos` on a one-element list, so the two
paths cannot drift. Per-recipe ordering is unchanged
(`order_index`-ordered images, ingredients and steps), tombstones and
rows whose recipe is gone render exactly as before, and an empty page
issues no recipe queries at all. A page costs eleven statements
regardless of its size.

### Verification

`tests/integration/sync/test_sync_feed.py` counts the statements the
engine actually executes through a `before_cursor_execute` listener.
Red, on the old code — the count grows linearly with the page, for
upsert pages and tombstone pages (the per-row `find()`) alike:

```text
E       AssertionError: a 6-change page cost 56 statements against 20 for a 2-change page: the page fans out per change
E       assert 56 == 20
E       AssertionError: an 8-tombstone page cost 10 statements against 4 for 2: the page still looks recipes up one by one
E       assert 10 == 4
FAILED tests/integration/sync/test_sync_feed.py::test_sync_page_statement_count_does_not_grow_with_the_page
FAILED tests/integration/sync/test_sync_feed.py::test_all_tombstone_page_needs_no_per_recipe_queries
2 failed, 4 passed in 4.85s
```

Green: both counts are flat in the page size, a tombstone page never
touches the child tables, an empty page issues exactly the sync-state
and change-window reads and nothing else, and a mixed page — full
graph, empty graph, tombstone — renders identically to single-recipe
reads with no leakage between page neighbours
(`test_batched_page_matches_single_recipe_reads`), alongside the
pre-existing pagination, replay and cursor-expiry tests:

```text
uv run pytest -q tests/integration/sync/test_sync_feed.py  -> 6 passed in 5.26s
uv run pytest -q -m "not live_provider and not chaos"      -> 760 passed
uv run ruff check ladle tests alembic                      -> All checks passed
uv run mypy --strict ladle                                 -> clean
```

## Where this run stopped, and where the next one starts

Every HIGH finding (#1–#10) is closed, plus MEDIUM #20, #21 and #24 — 13 of
the 45 — along with one defect the review had not found. 32 findings remain,
all MEDIUM or LOW.

### Not attempted, and why

- **#25 (GuestLimitView's fake account creation)** needs a product decision,
  not a fix. The sheet's "Create a free account" button only flips local
  `AccountState` to `.freeAccount`; whether that should call a real
  registration depends on whether real account creation exists yet, which is
  a question for the user rather than a guess to make here. Left untouched.
- **#30/#31/#32 (ImportCoordinator cancellation)** are the natural next
  group, and #24 already laid a seam for them:
  `RemoteContractError.importCancelled` is thrown but nothing catches it yet,
  so a cancelled job currently surfaces as a generic import failure. That
  cluster should decide how a cancelled job presents and catch it there.
- **#28 (hard delete without a tombstone)** is referenced by a comment in
  `markUpsertSynced`'s row-is-gone branch; that branch is deliberately a
  no-op until #28 provides the server-side delete.

### Suggested order for the next session

1. #30/#31/#32 together, catching `importCancelled` as part of it.
2. #27 and #28, which sit in the same `applySyncPage`/`deleteRecipe` code as
   this run's #7, #9 and the tombstone fix — that context is fresh in the
   commits above.
3. #11–#19, #22, #23 (backend MEDIUM), which are independent of each other.

### Known repository-level issue, untouched

`uv run ruff format --check .` reports 35 files that would be reformatted
under the locked ruff 0.16.0, all of them already drifted on `main`. Every
hunk this branch adds or modifies is formatted per that version, but two of
the 35 are files this branch also touches — `ladle/recipes/template_clone.py`
and `tests/integration/test_migrations.py` — whose drift sits in hunks this
branch did not change, so those files still fail the whole-file check.
Reformatting all 35 is a large mechanical diff that would bury this branch's
changes, so it is left for a separate commit.
