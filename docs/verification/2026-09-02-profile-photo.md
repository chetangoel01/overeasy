# A cook can choose their own profile photo

Date: September 2, 2026
Issue: [#75](https://github.com/chetangoel01/recipe-app/issues/75)
Status: **built and verified on the review simulator; the backend half is
verified against the Compose Postgres and a fake object store, and has not
been deployed.**

Companion to [Settings becomes Profile](2026-09-02-profile-sheet.md), which
made the avatar the subject of the screen. This gives a cook something to do
with it.

## Purpose

The avatar showed the provider's picture or a monogram, and the only thing
tapping it offered was **Show photo / Show initials**. There was no way to
choose a picture — the one thing a profile screen is expected to let you do —
and an Apple account never had a picture at all, because Apple supplies none.
A Google cook was stuck with whatever Google had, refreshed over them on every
sign-in.

## Behaviour

Tapping the avatar opens a menu, now for **every** signed-in cook rather than
only one a provider gave a photo to:

| Item | When |
| --- | --- |
| **Take Photo** | only where `UIImagePickerController.isSourceTypeAvailable(.camera)` |
| **Choose Photo** | always; the system photo picker, images only |
| **Show photo / Show initials** | when there is any photo to show — unchanged from before |
| **Remove Photo** | destructive, and only when the photo is the cook's own |

A chosen picture is centre-square-cropped, drawn at 512 pixels square with the
EXIF orientation applied, and encoded as JPEG at the first quality that fits
under 512 KiB. It appears in the avatar **immediately**, while the upload runs
behind it; a failure puts the previous picture back and says so in an alert
whose first sentence is "Your photo is unchanged."

Choosing a photo also flips the photo/initials toggle back to the photo. A
cook who was showing initials and then picks a picture means to see it.

**Remove Photo** clears the cook's photo and leaves whatever the provider
supplied — for a Google account, Google's picture returns; for an Apple
account, the monogram.

A cook's photo now survives every later sign-in. The provider's link still
refreshes in `users.avatar_url`, but it is no longer what is served.

## The wire

Two routes, and one new field on two responses.

`PUT /v1/auth/avatar` takes the JPEG as the **raw request body** with
`Content-Type: image/jpeg`, at most 512 KiB. It stores it at
`avatars/<user id>/<uuid>.jpg` in the existing private bucket and answers with
`ProfileResponse`. `DELETE /v1/auth/avatar` takes the photo away and answers
with the same shape.

`avatarURL` becomes a **signed read URL** for that object whenever the cook has
a photo, and the new `avatarIsCustom` says which of the two pictures it is —
the app cannot read that off a URL, and it must know, because only the cook's
own photo can be removed. The field is carried through `AccountProfile` and the
Keychain record.

Nothing re-signs a URL on demand and no endpoint was added for it: the profile
travels with the tokens, so `POST /v1/auth/refresh` — which a running app does
every fifteen minutes — is the refresh mechanism.

## Decisions

- **A separate column, not a reuse of `avatar_url`.** A bucket key is not a
  URL: what the app is served is minted per response and expires. Keeping them
  apart is also exactly what lets `merge.py` go on refreshing the provider's
  copy without ever overriding the cook's — the sign-in path needed no new rule
  at all, only the serving rule in `auth.py`.
- **Six hours of signature against fifteen minutes of access token.** Reused
  from the recipe-image signer rather than introduced: one signing lifetime for
  the whole bucket. The consequence, recorded because it is real: a cold launch
  after more than six hours idle draws the stored URL, which 403s, so the
  monogram shows until the first refresh replaces it — `AsyncImage` reloads on
  a URL change, so it corrects itself without anything else happening.
- **The raw body, not base64 in an envelope.** The JPEG is already the whole
  request; wrapping it would cost a third more bytes for nothing. It is the
  first non-JSON request the app makes, so `APIClient` grew a `Payload` enum
  and the 401 → refresh → replay loop is shared rather than copied.
- **Validated, not decoded.** The magic number `FF D8 FF` separates a JPEG
  from a PNG, a HEIC or a JSON body. Nothing on the server ever renders what a
  cook uploads, so decoding it would be work done only to create an attack
  surface.
- **No per-route rate limit,** because `PATCH /profile` has none either: both
  are covered by the global limiter. This writes one bounded object per
  account, and an account that replaces its photo twenty times in a minute has
  cost nothing worth a policy. Read as the plain sense of "rate-limit both like
  `PATCH /profile`".
- **No change to the body-limit middleware.** `maximum_request_body_bytes`
  defaults to 1 MiB, which already admits 512 KiB, and the middleware has no
  per-route mechanism. The route enforces its own cap and answers `413`.
- **Queued, never deleted inline.** A request that erases from the bucket and
  then fails to commit has destroyed something the row still points at. The
  shared `queue_object_deletion` is the insert four existing call sites write
  by hand.
- **The merge orphan, which the issue did not mention.** A guest can choose a
  photo and then sign into an account that already has one. The destination
  keeps its picture; the guest's object is queued in `_merge_users`, because
  the source user row is deleted along with the destination account and nothing
  else would ever have named that key again.
- **`DELETE` on an account with no photo is `200`, not `404`.** "There is no
  photo" is the state being asked for.
- **`avatarIsCustom` is `Bool?` on `AuthTokens`.** That type is the Keychain
  record, decoded on every launch. A non-optional flag would fail to decode
  every session written by today's build — signing out every cook on upgrade.
  It is `Bool` (defaulting false) on `AccountProfile`, where nothing is
  persisted, and it is deliberately not part of `AccountProfile.isEmpty`: a
  flag about a picture is not itself something to show.
- **`format.scale = 1` on the renderer.** Left at the screen's scale the same
  code renders 1024 pixels on a 2× device and 1536 on a 3× — four to nine times
  the bytes for a picture nothing draws larger than 96 points. Every assertion
  in `ProfilePhotoTests` is on `cgImage.width`, not on `UIImage.size`, for the
  same reason.
- **Aspect-fill drawing, not a `CGImage` crop.** `draw(in:)` applies the
  image's EXIF orientation and a bitmap crop does not, so a photo taken in
  portrait would otherwise be squared along the wrong axis and come back
  rotated.
- **No interactive crop in v1**, as the issue decided. The centre of a portrait
  is where a face already is.
- **`ProfileNameFailure` became `ProfileEditFailure`** with `name(_:)` and
  `photo(_:)`, rather than a second copy of the same switch. The only
  difference between the two messages is the first sentence.

## Affected components

**Backend**

- `Backend/alembic/versions/0023_hold_the_photo_a_cook_chose_for_themselves.py`
  — new; `users.avatar_object_key`, nullable.
- `Backend/ladle/db/models.py` — the column.
- `Backend/ladle/api/routes/health.py` — `expected_revision` → `"0023"`.
- `Backend/ladle/api/routes/auth.py` — `PUT`/`DELETE /avatar`, `_served_avatar`,
  `_profile_response`, `avatar_is_custom` on both responses.
- `Backend/ladle/auth/sessions.py` — `SessionTokens.avatar_object_key`.
- `Backend/ladle/api/app.py` — `SIGNED_READ_LIFETIME`, an injectable
  `object_storage`, and the signer hoisted onto `application.state.object_url`.
- `Backend/ladle/privacy/object_deletion.py` — new; the shared queue insert.
- `Backend/ladle/auth/merge.py` — the guest's orphaned photo, and the docstring
  that now says why the provider's link no longer decides what is shown.
- `Backend/ladle/auth/deletion.py` — the account's photo joins its images.
- `Backend/tests/api/test_avatar.py` (new, 15 cases),
  `Backend/tests/fakes/object_storage.py` (new),
  `Backend/tests/unit/auth/test_profile_wire.py`,
  `Backend/tests/integration/test_migrations.py`.
- `Backend/docs/integration-reference.md`, `docs/privacy-policy.md`.

**Shared**

- `Contracts/Fixtures/auth-tokens.json` — now a cook who chose their own photo,
  with a signed URL and `avatarIsCustom: true`.
- `Contracts/Fixtures/auth-profile.json` — an Apple cook with none, `false`.
- `Packages/LadleCore/Tests/LadleCoreTests/RemoteContractTests.swift`.

**iOS**

- `Ladle/Account/ProfilePhoto.swift` — new; crop, downscale, encode. Pure.
- `Ladle/Account/CameraPhotoPicker.swift` — new; the `UIImagePickerController`
  wrapper and the camera-availability check.
- `Ladle/Account/AccountHeaderView.swift` — the menu, the pickers, the pending
  picture, the second alert, `ProfileEditFailure`.
- `Ladle/Account/AuthClient.swift` — `uploadAvatar`, `removeAvatar`, and one
  private `apply(_:)` the three profile writes share.
- `Ladle/Remote/APIClient.swift` — the `Payload` enum and the raw-body request.
- `Ladle/Account/AccountSession.swift` — `AccountProfile.avatarIsCustom`,
  `-account-avatar-custom`.
- `Ladle/Account/KeychainTokenStore.swift` — `AuthTokens.avatarIsCustom`.
- `Ladle/Account/NameStepView.swift` — carries the flag through its own local
  `applyProfile`.
- `Config/Ladle-Info.plist` — `NSCameraUsageDescription`,
  `NSPhotoLibraryUsageDescription`.
- `LadleTests/ProfilePhotoTests.swift` (new),
  `LadleTests/AuthContractTests.swift`,
  `LadleUITests/ProfileSheetUITests.swift`.

## Verification

Every test here was written before the behaviour it covers, but only two were
actually watched fail: the backend suite was authored against routes that did
not exist yet and first *run* after they did, so its fifteen cases were
verified green rather than red-then-green.

The two that failed were `ProfilePhotoTests.testTheSquareIsTakenFromTheCentre`
and `testOrientationIsAppliedBeforeTheCrop`, and they failed for the wrong
reason: the *fixtures* were wrong, not the code. The centre square of a 3:1
field is its middle third, so a stripe a third wide filled the whole result and
the "white edges" the test expected could not exist. Both sources were rebuilt
— a narrow stripe, and a red-over-white split whose axis turns with the image —
and `ProfilePhoto` itself was not touched.

Backend, from `Backend/`:

- `uv run ruff format --check .` — 335 files already formatted
- `uv run ruff check .` — All checks passed
- `uv run mypy --strict ladle` — no issues in 124 source files
- `uv run pytest` — **893 passed**

Shared:

- `swift test --package-path Packages/LadleCore` — **56 tests in 10 suites
  passed**

iOS, on the iPhone 17 / iOS 26.5 simulator reserved for tests:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,id=1CE0C07F-8CDD-41E5-9B38-DD908B5F5CBD' \
  -only-testing:LadleTests \
  -only-testing:LadleUITests/ProfileSheetUITests \
  -only-testing:LadleUITests/DiscoverInteractionUITests
```

`** TEST SUCCEEDED **`, with these `Executed` lines:

| Suite | Result |
| --- | --- |
| `LadleTests.xctest` | Executed **461** tests, with 1 test skipped and 0 failures |
| `DiscoverInteractionUITests` | Executed **7** tests, with 0 failures |
| `ProfileSheetUITests` | Executed **7** tests, with 0 failures |
| `LadleUITests.xctest` | Executed **14** tests, with 0 failures |

`DiscoverInteractionUITests` is seven cases, not the thirteen the September 2
Profile document reports: it was cut back by
[the test pruning](2026-09-02-test-pruning.md) later the same day.

New tests: `ProfilePhotoTests` (seven — the two square sizes, the centre crop,
the orientation, an ordinary photo under the cap, the quality loop driven by a
tiny cap over random noise, and the refusal when nothing fits), three cases in
`AuthContractTests` (the fixture's flag, a Keychain record written without it,
and that the flag alone is not a profile), two in `AccountSessionTests`
(`-account-avatar-custom`, and `applyProfile` carrying the flag), two in
`ProfileSheetUITests` (the menu offers Choose Photo, and offers Remove Photo
only with `-account-avatar-custom`), fifteen in
`Backend/tests/api/test_avatar.py`, two in `test_profile_wire.py` and one
migration case.

## Captures

`docs/verification/captures/2026-09-02-profile-photo/`, on the "Overeast UI
validation" simulator (iPhone 17, iOS 26.5, 402×874 pt), Debug build,
`-ui-testing -onboarding-complete -reset-library-preferences -account-state
signedInWithGoogle -account-display-name "Priya Raman" -account-created-at
2026-08-14T12:00:00Z`, accent pinned to tomato, status bar frozen at 9:41 and
cleared afterwards.

| File | What |
| --- | --- |
| `avatar-menu.png` | the menu on a monogram — Take Photo and Choose Photo, nothing else to offer |
| `after-photo-chosen.png` | a photo picked from the simulator's library, centre-cropped and applied |
| `avatar-menu-with-remove.png` | the same menu once the photo is the cook's: the photo/initials choice and Remove Photo have appeared |

The first capture is the case the issue was about — an account with no picture
at all, where the avatar used to do nothing when tapped.

"Take Photo" **is** present in these captures. An iOS 26 simulator reports a
camera, so `isSourceTypeAvailable(.camera)` is true there; the item is hidden
only on a device that genuinely has none. The UI tests deliberately do not
assert on it for that reason.

The captures are taken through the no-`AuthClient` path — `-ui-testing` builds
the demo services — so the chosen photo is processed by `ProfilePhoto` exactly
as it would be before an upload and then applied from a temporary file rather
than sent. What is photographed is the menu, the crop and the header, not the
round trip.

## Not verified

**End-to-end against a deployed backend.** The routes are exercised against the
Compose Postgres and a dictionary-backed object store, and the wire shape
against the golden fixtures on both sides, but no build has talked to a server
serving `avatarIsCustom`.

That ordering is not a hazard. `avatarIsCustom` is optional in both places the
app reads it, so a build talking to an API that predates the field simply never
offers "Remove Photo" — and `PUT /v1/auth/avatar` on such an API answers 404,
which the header reports through the same alert every other failure uses.

**A real signed URL expiring.** The six-hour lifetime is asserted only as the
value passed to the signer; nothing has waited six hours to watch a URL go
stale and a refresh replace it.

**MinIO.** The route tests use a fake object store rather than the Compose
MinIO, so the key shape and the `put`/`signed_read_url` calls are verified but
the S3 round trip for an avatar is not. `S3ObjectStorage` itself is unchanged
and is covered by the existing thumbnail integration test.
