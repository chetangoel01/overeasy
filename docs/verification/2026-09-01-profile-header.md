# The cook, captured and shown

Date: September 1, 2026
Issue: [#42](https://github.com/chetangoel01/recipe-app/issues/42)
Backend half: [PR #43](https://github.com/chetangoel01/recipe-app/pull/43)
Status: **built and verified on the review simulator; not yet run against a
backend that has migration 0021.**

## What was wrong

Two things, and only one of them was visible.

**The invisible one is the urgent one.** The app asked Apple for `.fullName`
and Google for a profile, then discarded both: `handleAppleCompletion` read the
identity token and the authorization code out of the credential and nothing
else. Apple returns a full name **exactly once**, on the first authorization
for a given Apple ID and app — it is in no token and never comes again. Every
sign-in that happened without this lost that cook's name permanently.

**The visible one:** Settings showed a signed-in cook the same screen as a
guest with one string changed — "Signed in with Google" beside a green
Connected pill — and nothing about the person signed in. There was no profile
to show, which is why: `users` held an id, a kind and a timestamp.

## What changed

### The client half of the capture (`AuthTokens`, `AccountSession`, `AuthClient`)

The profile rides on the tokens rather than behind a `GET /me`: `userKind`
already travelled there, the Keychain record is the same type, and `/refresh`
keeps it current for free.

- `AuthTokens` gains `displayName` and `avatarURL`. Both are optional on the
  wire and absent from tokens written by older builds, so both decode as nil
  rather than failing a session. The Swift property is `avatarURL`, not
  `avatarUrl`: the backend's wire alias generator rewrites a trailing `Url` to
  `URL`, the same shape that already gives `userID` and `deviceID`.
- `applyRemoteUserKind` widened to `applyRemoteAccount(kind:profile:)`. The
  backend stays authoritative about the profile for the same reason it is
  authoritative about the kind. `signOut` clears it.
- `AccountSignInFlow.displayName(from:)` formats `credential.fullName` with
  `PersonNameComponentsFormatter` and clamps to 64 characters — the bound the
  server enforces, past which the request is rejected outright and the sign-in
  fails rather than the name arriving shortened. Empty components (every
  sign-in after the first) produce nil, and nil encodes as an **absent key**,
  never an empty string, so a later sign-in cannot blank a stored name.
- `AuthClient.updateProfile(displayName:)` PATCHes `/v1/auth/profile` and
  writes the answer back into the Keychain as well as the session. A relaunch
  reads the Keychain, not the server, so an edit that only reached the session
  would come back undone.
- `APIClient` gained a `sessionRefreshed` hook beside the existing
  `authenticationExpired` one, so a refresh applies the profile it returns.
  That is how a name edited on another device reaches this one.

### The header

The first section of the Settings form, with a clear row background and zero
insets, is now the cook:

- **Signed in.** A 64-point avatar, the display name in `recipeTitle`, the
  account kind beneath in `metadata`. The avatar is the provider's photo via
  `AsyncImage`, or a monogram on `Surface.badge` — the monogram doubles as the
  photo's placeholder, so nothing pops in from empty. A `Menu` on the avatar
  switches between them, offered **only when a photo exists**: Apple never
  supplies one, and a menu with a single option that changes nothing is worse
  than no menu. The choice is per device (`ladle.profile.avatarStyle`); the
  name is what has to survive a reinstall, and that lives on the account.
- **Editing.** Tapping the name replaces it with a centred field: 64
  characters, `.submitLabel(.done)`, `PATCH` on submit. A failed save shows an
  alert and the name is already back, because what is drawn comes from the
  session that the failed request never touched.
- **Guest.** The word "Guest" and a `Sign in` button, nothing else — no empty
  avatar and no placeholder name, because a guest has neither. The button
  presents a sheet carrying the same Apple and Google buttons the rest of the
  app uses.

`SignInOptionsView` is that pair, extracted. There were three copies of the
same twenty lines and they had already drifted: the welcome screen clipped its
Apple button and the guest-limit sheet bordered its Google one. The one thing
that legitimately differs is the ground they sit on, so that is the parameter
(`.porcelain` / `.graphite`); everything else is shared.

## Decisions taken here

| Decision | Why |
| --- | --- |
| A signed-in cook with no name shows "Add your name" and a `person.fill` avatar | Every Apple cook who signed in before the capture has no name. A blank header reads as broken; this reads as an invitation, and the tap target is the edit that fixes it. |
| A blank submit is sent as typed | The server's contract: blank clears the name back to the provider's. Refusing it client-side would remove the only way to undo an edit. |
| `.undecided` is drawn as a guest | It is the pre-sign-in state; there is no account to describe. |
| The cook's own edit applies even to a launch-argument-pinned profile | The pin exists so the guest registration cannot wipe a UI-test fixture, not to stop the person using the app. Without this the name is uneditable in exactly the builds a reviewer can run. |
| The avatar diameter is a local constant, not a theme token | `Control` names the three heights a *tappable control* may have. The avatar is artwork; adding a fourth control height would say something false about the scale. |

## Verification

Unit suite, under the watchdog (the process prints its results and never
exits):

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LadleTests
```

- Red first, production changes stashed: `Testing cancelled because the build
  failed`, 20 errors, all of them the new API the tests reach for.
- Green: `Executed 373 tests, with 1 test skipped and 0 failures (0
  unexpected)` — 12 new.

New coverage: the profile applied with the account and cleared on sign-out; a
launch-argument profile pinned and an edit still landing on it; the profile
decoded from a tokens response into both the session and the Keychain; tokens
without a profile restoring as a profile-less session; `fullName` present in
the Apple request body when supplied and the key **absent** when not; `PATCH`
sent, its answer stored, and the avatar not dropped by a name edit; the Apple
name formatted and bounded to 64 characters.

UI tests:

```
xcodebuild test ... \
  -only-testing:LadleUITests/DiscoverInteractionUITests/testSettingsHeaderShowsTheSignedInCook \
  -only-testing:LadleUITests/DiscoverInteractionUITests/testSettingsAccentAndRecipeViewPreferencesAreReachable
```

`Executed 2 tests, with 0 failures (0 unexpected)`. The new one launches
`-ui-testing -onboarding-complete -account-state signedInWithGoogle
-account-display-name "Priya Raman"`, opens Settings and asserts the header.
The name is queried by identifier, not as static text: it is a button, because
tapping it edits.

Captures on the review simulator (`614AF85D-…`), status bar frozen at 9:41 and
cleared afterwards, in `captures/2026-09-01-profile-header/`:
`before-signed-in.png`, `before-guest.png`, `after-signed-in-photo.png`,
`after-signed-in-monogram.png`, `after-guest.png`. The photo state used a real
resolvable avatar URL (`https://i.pravatar.cc/256`), since `AsyncImage` needs
one; the monogram state is `-account-state signedInWithApple`, which is the
real Apple case as well as the fixture.

Also driven by hand on that simulator: the avatar menu switches to initials and
back, the name field takes focus on the first tap, and the guest sign-in sheet
presents and dismisses.

## Not verified

**End-to-end against a backend.** The Compose API on this machine is built from
`main` and lacks migration 0021, so it would reject `fullName` and know nothing
of `PATCH /v1/auth/profile`. Nothing here has run against a server that has the
columns.

That is also the deploy constraint: **#43 must be deployed, not merely merged,
before a build carrying this reaches TestFlight.** A client that forwards
Apple's one-shot name to a server without the column loses that name for good —
the exact failure this change exists to stop.
