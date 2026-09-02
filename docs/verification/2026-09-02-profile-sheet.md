# Settings becomes Profile, and new cooks are asked their name

Date: September 2, 2026
Issue: [#62](https://github.com/chetangoel01/recipe-app/issues/62)
Status: **built and verified on the review simulator; the backend half is
verified against the Compose Postgres but has not been deployed.**

Companion to [the cook, captured and shown](2026-09-01-profile-header.md),
which put a name and a face on the account, and [Settings as a grouped
form](2026-09-01-settings-form.md), which put them on the platform's own
furniture. This is the third and last of that sequence: the screen stops
being Settings that happens to start with a person and becomes a Profile
that happens to end with settings.

Followed by [a cook can choose their own profile
photo](2026-09-02-profile-photo.md), which gives the avatar this screen is
built around something to do.

## Purpose

Two things a cook could not do, and one they were told too much about.

- **The screen was still Settings.** It was led by the cook after
  2026-09-01, but a 64-point avatar above five sections of preferences reads
  as a row that happens to come first. Nothing on it said anything about the
  cook's own cooking.
- **Half of the accounts had no name.** Apple returns a full name exactly
  once, on the first authorization, and only if the cook allows it. An Apple
  cook who declined — or any Apple cook who signed in before #42 landed —
  reached a header reading "Add your name" and was never asked.
- **Every section carried a paragraph of prose.** "Tints buttons, favorites,
  and the selected tab." under five colored circles; "What Overeasy stores,
  and what it never does." under one row that says exactly that.

## Behaviour

### Profile (the sheet)

Reached from the same toolbar control, whose accessibility label is now
**"Profile"** rather than "Settings and account"; the navigation title is
**"Profile"**. The header, centred on porcelain:

- a **96-point** avatar — the provider's photo when there is one, otherwise
  the monogram, with the photo/initials menu unchanged;
- the display name in the **title** face, still edited in place by tapping
  it, exactly as before;
- the provider line ("Signed in with Google");
- one **facts line** in the metadata style:
  `6 recipes · 2 favorites · cooking since August 2026`.

The counts come from the library on the device. Singulars are singular
("1 recipe", "1 favorite"), zero stays plural, and the spelling is American
throughout — every user-facing string in the app is, even though these
documents are not. "cooking since" appears only when the account's creation
date is known, and the line simply shortens when it is not.

A guest sees "Guest" in the same face, `6 recipes on this device`, and the
Sign in button as before. No invented avatar and no placeholder name.

Below the header, the same five sections, now **rows and headers only**. The
section header "Account actions" is renamed **"Account"**. The confirmation
dialog for sign-out and the alert for account deletion keep their own copy —
that text is read immediately before something irreversible, which is the
one place a paragraph earns its place.

### The name step

A fourth root state in `RootView`, between the welcome screen and the
walkthrough. Every new Apple or Google account passes through it once:

- Skip top-right, the title "What should we call you?", and one secondary
  line, "It's how Overeasy greets you. You can change it any time in your
  profile."
- A 96-point monogram whose initials follow the field as it is typed, with
  the same `person.fill` placeholder the header uses when it is empty.
- A centred field in the recipe-title face, placeholder "Your name", `words`
  capitalisation, autocorrect off, capped at `AccountProfile.displayNameLimit`.
- A primary **Continue** pinned above the safe area, disabled while the
  trimmed text is empty.
- **The keyboard comes up on arrival.**

Prefilled from `accountSession.profile?.displayName` — Google always, Apple
on its first authorization — and empty when Apple withheld it. Continue
submits through `AuthClient.updateProfile`, or through
`accountSession.applyProfile` when there is no client, exactly as the
header's inline edit does. A prefilled name accepted unchanged sends
nothing: there is no round trip to fail on the happy path.

A failed save keeps the screen and prints the header's own failure copy
under the field. Skip always works. Guests are never asked, and a guest who
signs in later reaches the step through the same `onAuthenticated` path a new
account does.

## The two corrections asked for on the prototype

### (a) The dead space at the top of the sheet

Measured with XCUITest frames, which are in points and reproducible, as
`avatar.frame.minY - navigationBar.frame.maxY` on an iPhone 17 at 402×874:

| | Gap |
| --- | --- |
| Before (`main`) | **59.0 pt** |
| After | **24.0 pt** |

It was two things stacked: the grouped form's own first-section inset (about
35 points) and the header's `.padding(.vertical, LadleTheme.Layout.sectionGap)`
(24) on top of it. Both are addressed —

- the header contributes **no top padding at all** now, only bottom;
- the form sets `.contentMargins(.top, 24, for: .scrollContent)`, which
  *replaces* the first-section inset rather than adding to it, so 24 points
  is the whole gap.

`.listSectionSpacing` was the wrong tool: it governs the space *between*
sections, not above the first one. The measurement is now an assertion —
`ProfileSheetUITests.testProfileOpensOnTheCookRatherThanOnEmptySpace`, with
a ±6 pt tolerance so the platform may move but the 24 points of padding
cannot come back.

### (b) The footers

Four strings are gone, and the header's footer with them:

- "Your recipes stay synced across your devices."
- "Tints buttons, favorites, and the selected tab."
- "What Overeasy stores, and what it never does."
- "Signing out keeps your synced library in Overeasy. Deleting removes it
  permanently."

`AccountSheet.accountDetail(for:)` produced the first of those and had no
other caller, so it is deleted along with its assertion in
`ProjectSmokeTests`. `ProfileSheetUITests.testProfileHasNoExplanatoryFooters`
asserts all four are absent and that the section headers stayed.

## Decisions

- **The header grew; it was not replaced.** The prototype's
  `ProfileIdentityView` dropped tap-to-edit and the photo/initials menu, both
  of which had to stay, so `AccountHeaderView` was grown in place and the
  prototype file was not lifted.
- **`created_at` is required on the wire, not nullable.** Every `users` row
  has one. A client that had to handle a missing date would need a second
  story for a case the server cannot produce. It is server-owned in the
  strong sense: no request field, and `ProfileUpdateRequest` forbids extras.
- **`AccountProfile.createdAt` is optional on the client**, because a
  Keychain record written by an older build genuinely has no date. That
  makes it part of `isEmpty`, which means a guest — who has no name and no
  avatar — now has a non-nil profile carrying only a date. Every branch that
  distinguishes a guest keys off `AccountSession.state`, not off the profile;
  `AuthContractTests.testAGuestProfileIsCarriedByItsCreationDateAlone` pins
  that.
- **Only a *new* sign-in is asked, not a restored session.**
  `restoreAndLoad()` runs the backend's answer back through the same
  `completeWelcome` path a sign-in takes, on every cold launch. Without a
  transition check, every cook already signed in when this ships would have
  been stopped once on upgrade by a question about their name. The gate is
  that a sign-in **changes** the account — undecided or guest becoming Apple
  or Google — while a restore hands back the kind it was given; or that the
  store says the step is still pending, which is how a relaunch part-way
  through it resumes.

  A first attempt asked instead "was the previous state not an account?",
  and the manual run on the review simulator caught it: a device whose
  stored `ladle.account.state` had outlived its onboarding flags reached the
  welcome screen with the state already Apple, so signing in with Google
  skipped the step entirely. `testSigningInOverAStaleAccountStateStillAsks`
  is that case. It is the one bug this change had that the unit tests did
  not find on their own — the launch-argument path sets the pending flag
  directly and never exercises `completeWelcome`.
- **`shouldPresentNameStep` is derived exactly like
  `shouldPresentWalkthrough`** — a pending flag persisted before the screen
  appears and a completion flag that ends it — so quitting mid-step resumes
  and a finished step never returns. Both Continue and Skip complete it: a
  cook who declined to give a name has answered the question.
- **The name-step completion is cleared on sign-out, unlike the
  walkthrough's.** The walkthrough teaches the device the app once; the name
  belongs to the account. Whoever signs in next is a new cook and is asked
  their own.
- **`-onboarding-complete` now also completes the name step.** It is an
  onboarding step and that argument already completes the walkthrough — and
  a UI-test container keeps its `UserDefaults` between tests, so one test
  leaving the step pending would otherwise strand every later test in the run
  behind it. `-name-step-complete` skips it on its own and
  `-name-step-pending` forces it; the force is read last so it wins.
- **The keyboard is raised after one turn of the run loop.** This view fades
  in as a root state, and focus set during that transition is dropped.
- **The field needs its own hit area.** An empty SwiftUI `TextField` is
  tappable only on the line the caret would sit on, so the padded row around
  it carries `.contentShape(Rectangle())` and a tap that sets focus. The
  empty-case UI test taps the row before typing, so a dead row fails it.

## Affected components

**Backend**

- `Backend/ladle/auth/sessions.py` — `SessionTokens.created_at`, required,
  read from `User.created_at`.
- `Backend/ladle/api/routes/auth.py` — `created_at` on `AuthTokensResponse`
  and `ProfileResponse`.
- `Contracts/Fixtures/auth-tokens.json`, `auth-profile.json` — new; the auth
  responses had no golden fixture at all.
- `Backend/tests/unit/auth/test_profile_wire.py`,
  `Backend/tests/contracts/test_golden_fixtures.py`,
  `Backend/docs/integration-reference.md` (the route inventory also gained
  `/google`, `PATCH /profile` and `DELETE /account`, which were missing).

No migration: `users.created_at` already exists.

**Shared**

- `Packages/LadleCore/Tests/LadleCoreTests/RemoteContractTests.swift` — the
  auth wire shape, decoded from the same fixtures the backend re-emits.

**iOS**

- `Ladle/Account/AccountSession.swift` — `AccountProfile.createdAt`,
  `shouldPresentNameStep`, `completeNameStep()`, the two name-step launch
  arguments and `-account-created-at`.
- `Ladle/Account/KeychainTokenStore.swift`, `Ladle/Account/AuthClient.swift`
  — `createdAt` stored beside the tokens and mapped from both responses.
- `Ladle/Account/AccountHeaderView.swift` — 96-point avatar, the facts line
  (`ProfileFacts`), the guest identity, no top padding; the failure copy is
  hoisted into `ProfileNameFailure` so the name step shares it.
- `Ladle/Account/AccountSheet.swift` — "Profile", no footers, "Account", the
  first-section inset.
- `Ladle/Account/NameStepView.swift` — new.
- `Ladle/App/RootView.swift` — the fourth root state.
- `Ladle/Library/LibraryView.swift` — the toolbar label.

## Verification

Tests were written before the behaviour they cover, but only two of them
were watched fail first (the LadleCore fixture's epoch constant and the
`AuthClient` profile stub, both caught by the suite rather than authored
red). The rest were verified green after the fact rather than red-then-green.
The commits were also not built in isolation: the split is sound by
construction — the second compiles without the root wiring, and the third
adds the view, the wiring and the UI tests together — but the run below
covers the final tree only.

Backend, from `Backend/`:

- `uv run ruff format --check .` — 331 files already formatted
- `uv run ruff check .` — All checks passed
- `uv run mypy --strict ladle` — no issues in 123 source files
- `uv run pytest` — **875 passed**

Shared:

- `swift test --package-path Packages/LadleCore` — **56 tests in 10 suites
  passed**

iOS, on the iPhone 17 / iOS 26.5 simulator reserved for tests:

```
xcodebuild test -project Ladle.xcodeproj -scheme LadleAllTests \
  -destination 'platform=iOS Simulator,id=1CE0C07F-8CDD-41E5-9B38-DD908B5F5CBD' \
  -only-testing:LadleTests \
  -only-testing:LadleUITests/DiscoverInteractionUITests \
  -only-testing:LadleUITests/StateScenarioUITests \
  -only-testing:LadleUITests/ProfileSheetUITests
```

`** TEST SUCCEEDED **`, with these `Executed` lines:

| Suite | Result |
| --- | --- |
| `LadleTests` | Executed **449** tests, with 1 test skipped and 0 failures |
| `DiscoverInteractionUITests` | Executed **13** tests, with 0 failures |
| `ProfileSheetUITests` | Executed **5** tests, with 0 failures |
| `StateScenarioUITests` | Executed **7** tests, with 0 failures |
| `LadleUITests.xctest` | Executed **25** tests, with 0 failures |

One flake seen on the way, worth recording because it is not this change's:
`DiscoverInteractionUITests.testWatchDefaultsToInlinePlayerWithPlaybackControls`
failed once, on a run during which a Debug build was compiling on the same
machine. It waits 3 seconds for the inline player and the test takes 28
seconds end to end, so it is thin on a loaded machine. It passed on the run
before and on the clean run above; nothing about it was changed.

New tests: `LadleTests/ProfileFactsTests.swift` (the facts-line wording),
`LadleTests/AuthContractTests.swift` (the fixtures, the Keychain round trip,
the guest profile), ten name-step cases in `AccountSessionTests` and two
for `-account-created-at`, and
`LadleUITests/ProfileSheetUITests.swift` (the gap, the footers, the guest
header, and both name-step cases).

`StateScenarioUITests` needed **no change**: nothing in it crosses welcome →
walkthrough. `testWelcomeAtAccessibilitySizeRemainsReachable` launches with
`-reset-onboarding` and stops at the welcome screen, and every other scenario
uses `-onboarding-complete`, which now completes the name step too. That
argument is what actually protects them.

## Captures

`docs/verification/captures/2026-09-02-profile-sheet/`, on the "Overeast UI
validation" simulator (iPhone 17, iOS 26.5, 402×874 pt), Debug build,
`-ui-testing -onboarding-complete -reset-library-preferences` plus the
`-account-*` arguments, accent pinned to tomato, status bar frozen at 9:41
and cleared afterwards.

| File | What |
| --- | --- |
| `before-settings.png` | today's sheet, from an unmodified `main` build |
| `after-profile-signed-in.png` | Profile, Google account, facts line |
| `after-profile-guest.png` | Profile as a guest |
| `after-name-step-prefilled.png` | the name step, prefilled, keyboard up |
| `after-name-step-empty.png` | the name step empty, Continue disabled |

The review simulator had a hardware keyboard attached, which suppresses the
software one. It was disconnected with
`defaults write com.apple.iphonesimulator ConnectHardwareKeyboard -bool false`
and a restart of Simulator.app before the prefilled capture, so the keyboard
in that PNG is the one a cook actually sees. iOS then showed its own
one-time "slide your finger across the letters" QuickPath card over the
keyboard on first appearance; it was dismissed before the capture.

`after-name-step-prefilled.png` is taken from the **real** path rather than
the launch argument: `-ui-testing -reset-onboarding -account-display-name
"Priya Raman"`, then Sign in with Google on the welcome screen. That is the
transition where focus can be dropped, so it is the one worth photographing;
Continue from there lands on the walkthrough, and the walkthrough on the
library.

## Not verified

**End-to-end against a deployed backend.** `created_at` is exercised against
the Compose Postgres by the backend suite and against the golden fixtures on
both sides, but no build has talked to a server that is serving the new
field.

That ordering is deliberately not a hazard, unlike #43's. The client is
lenient about the field in both places it reads it: `AuthTokens.createdAt`
and `AuthClient.ProfileResponse.createdAt` are both optional, so an app
talking to an API that predates the field loses the "cooking since" clause
and nothing else — no failed sign-in, and no name edit that fails on a
decode.
