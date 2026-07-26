# First-Run Experience Refinement

## Purpose

Move a new user from launch to the first useful recipe action with less
ceremony, while covering the empty, loading, recovery, and accessibility
details around that path.

The activation goal is the first structured recipe created from a saved link.
The audience is a mixed-experience home cook using the app one-handed.

## User-visible behavior

- The system launch surface now uses the Paper asset, avoiding a white flash
  before the app's warm browsing surface appears.
- First launch presents one dedicated full-screen welcome surface instead of a
  popup over the library. It states the link-to-recipe promise, then moves
  directly into account entry without repeating the same benefits in a
  feature list.
- The welcome uses the exact fried-egg mark shipped as the app icon.
- Continue with Apple and Sign in with Google handle both account creation and
  returning sign-in. A short "Start your recipe box" handoff explains why an
  account helps before presenting the controls. Guest entry is a quiet,
  full-width action with the ten-recipe limit and lossless later sign-in stated
  before entry.
- Google sign-in uses Google's current pre-approved neutral iOS artwork inside
  the same 52-point bounds and 15-point continuous corner treatment as the
  Apple control. Authentication still uses the official SDK, backend ID-token
  verification, and lossless guest-account merging.
- Authentication shows disabled controls, visible progress, and concise
  recovery copy when the backend or Apple flow cannot complete.
- The first account choice opens a three-step, skippable walkthrough of the
  real product loop: share a social recipe to Overeasy, review the rescued
  ingredients and steps, then cook in Focus mode with timers.
- The walkthrough uses the existing lemon-orzo recipe artwork and
  product-shaped examples rather than generic feature illustrations. Its
  progress and primary action remain visible while page content scrolls at
  large Dynamic Type sizes.
- An unfinished walkthrough resumes after relaunch. Finishing or skipping it
  persists completion, and signing out does not make it replay for a returning
  user.
- A genuinely empty Home view now explains what will appear, opens the real
  Add Recipe sheet, and teaches Share Extension use at the point it matters.
- Empty All Recipes removes irrelevant sort and filter controls, then offers
  the same first-recipe action.
- The library is neither rendered nor exposed to accessibility while the
  welcome surface is active. Welcome content scrolls independently at large
  Dynamic Type sizes while account actions remain reachable.
- Disabled primary and secondary buttons now expose a consistent muted visual
  state throughout the app.

## Decisions

- Treat authentication as its own destination. It fills the device and owns
  the accessibility tree until an entry path succeeds.
- Keep first-run education brief and task-shaped. The walkthrough teaches only
  the three actions needed to understand Overeasy, then hands off to the empty
  library's real first-recipe action.
- Present the walkthrough after the account choice so provider authentication
  stays focused and users learn only after they have entered the product.
- Track walkthrough completion separately from the older welcome preference.
  A pending marker resumes interrupted first-time flows without forcing the
  new walkthrough onto existing installations.
- Reuse the installed app icon artwork as the brand mark instead of maintaining
  a second onboarding identity.
- Use Google's pre-approved neutral button asset instead of the SDK's visually
  dated embedded wide control. The asset was downloaded from Google's
  [Sign in with Google branding guidelines][google-branding] on 2026-07-26.
- Use the official Google SDK and validate server-facing ID tokens against
  Google's rotating JWKS, expected issuer, server client audience, issue time,
  and expiry before merging an account.
- Show the first-use state only when both recipes and import jobs are empty.
  Active or recoverable imports continue to use the existing inbox behavior.

## Affected components

- `Config/Ladle-Info.plist`
- `Config/Debug.xcconfig`
- `Config/Release.xcconfig`
- `Ladle/Account/WelcomeView.swift`
- `Ladle/Account/OnboardingWalkthroughView.swift`
- `Ladle/Account/GoogleSignInProvider.swift`
- `Ladle/Account/AuthClient.swift`
- `Ladle/Account/AccountSession.swift`
- `Ladle/App/LadleApp.swift`
- `Ladle/App/RootView.swift`
- `Ladle/Resources/Assets.xcassets/GoogleSignInNeutral.imageset`
- `Ladle/Resources/Assets.xcassets/OvereasyMark.imageset`
- `project.yml`
- `Backend/ladle/auth/google.py`
- `Backend/ladle/auth/merge.py`
- `Backend/ladle/api/routes/auth.py`
- `Backend/ladle/db/models.py`
- `Backend/alembic/versions/0007_add_google_identity.py`
- `Ladle/Design/LadleComponents.swift`
- `Ladle/Library/LibraryView.swift`
- `Ladle/Library/LibraryHomeView.swift`
- `Ladle/Library/AllRecipesView.swift`
- `LadleTests/ProjectSmokeTests.swift`
- `LadleUITests/LadleLaunchTests.swift`
- `LadleUITests/AccessibilityTests.swift`
- `DESIGN.md`
- `README.md`

## Verification

- UI coverage was written first and observed failing against the passive tour,
  seeded empty launch, generic All Recipes state, and exposed background
  controls.
- The welcome polish regression was written first and observed failing while
  the repeated value rows were still present and the recipe-box handoff was
  absent. It now verifies the provider controls share full-width 52-point
  bounds.
- Focused red-green coverage verifies the concise welcome, guest handoff,
  empty Home and All Recipes actions, and the real Add Recipe presentation.
- Account-session coverage was written first and observed failing before
  walkthrough state existed. It now verifies first-account presentation,
  interrupted-flow resume, completion persistence, and no replay after
  sign-out.
- The first-account UI journey verifies all three lessons and the handoff to
  the library. Simulator screenshots of the share, review, and cooking steps
  were reviewed at the default content size.
- iPhone 17 Pro screenshots were reviewed at the default content size and
  Accessibility Large for the welcome and empty Home state.
- Accessibility Large coverage verifies that Apple, Google, and guest actions
  remain visible, scrollable, and at least 44 points tall. Separate walkthrough
  coverage verifies that Skip and Next retain 44-point hit targets while the
  lesson content scrolls.
- The `-empty-library` launch argument keeps UI testing deterministic without
  changing production persistence behavior.
- The focused authentication run passed 12 account/session and client tests.
  The focused welcome run passed its full-screen journey and Accessibility
  Large checks, including the official Google control's hit target.
- The complete final app bundle passed 124 unit tests. All 25 UI tests passed
  across the welcome, library, settings, import, recipe, cooking, Health, and
  share-extension matrix.
- Google verification and merge coverage passed as part of the 322-test
  backend suite; 3 environment-dependent integration tests were skipped.
- `LadleCore` passed all 37 tests across eight suites.
- The generic iOS Simulator milestone build compiled both Ladle and
  LadleShare, and `git diff --check` passed.

[google-branding]: https://developers.google.com/identity/branding-guidelines
