# Overeasy production-readiness pass

## Purpose

Re-audit the complete iOS frontend, share extension, account controls, release
metadata, and TestFlight packaging path before the first 1.0 beta.

## User-visible behavior

- The share extension now uses the Overeasy name and current warm palette in
  loading, success, and failure states.
- Share confirmation supports Dynamic Type, scrolls when content is taller than
  the extension, and keeps its close control at least 44 points.
- Home's Import Inbox card now uses sibling navigation and dismiss controls, so
  the dismiss target cannot intercept the card's navigation action. Both
  controls meet the 44-point minimum target.
- Nutrition macros expose stable identifiers and complete VoiceOver labels such
  as “Protein, 16 g.”
- Watch share, favorite, and panel controls meet the 44-point minimum target.
- Focus mode uses sentence-case step and timer labels.
- Remaining user-visible Ladle copy in import, re-import, notifications, timers,
  Health export, and fatal error states now consistently says Overeasy.
- Account settings now distinguish reversible sign-out from permanent account
  deletion. Deletion requires explicit destructive confirmation, preserves the
  account when the server request fails, and removes local data only after the
  server succeeds.
- Apple-account deletion revokes the stored Sign in with Apple refresh token
  before removing account data. The refresh token is encrypted at rest.
- Guest bootstrap and sensitive authenticated requests now use Apple's App
  Attest protocol. Assertions are bound to each exact request body, counters
  prevent replay, and production backend startup fails closed when verification
  is not configured.
- First launch is now a dedicated full-screen authentication destination using
  the installed app's fried-egg mark. It offers Apple, Google, and guest entry
  without rendering the recipe library behind it.
- Google sign-in uses the official iOS SDK and a backend-owned ID-token
  verifier. Existing guest recipes, imports, and device state merge into the
  Google account instead of being discarded.

## Release decisions

- Marketing version is `1.0`; this candidate uses build `20260726.2`.
- App and share-extension versions come from shared Xcode build settings so they
  cannot drift.
- `ITSAppUsesNonExemptEncryption` is false because the app uses only exempt
  system transport/security functionality and a one-way hash.
- `PrivacyInfo.xcprivacy` declares app-only `UserDefaults` access with required
  reason `CA92.1`; tracking is disabled.
- The Release API endpoint remains `https://api.ladle.app`, but the 2026-07-26
  live boundary check found that this hostname does not currently terminate TLS
  and its HTTP endpoint serves a parked-domain page. This is a release blocker,
  not an app-code failure.
- Account deletion is a server-authoritative operation. A failed Apple token
  revocation or backend deletion leaves local authentication and recipes intact
  so the user can retry.

## Affected components

- `Ladle/Account`: deletion UI and authenticated client operation
- `Ladle/App` and `Ladle/Library`: deletion dependency wiring and local cleanup
- `Ladle/Nutrition`, `Ladle/Cooking`, `Ladle/Library`: accessibility,
  interaction, brand, and design-system hardening
- `LadleShare`: branded, Dynamic Type-safe confirmation states
- `Config`, `project.yml`, and `Ladle/Resources`: build number, encryption
  declaration, App Attest environment, and privacy manifest
- `Ladle/Account/AppAttestClient.swift`, authenticated remote clients,
  `Backend/ladle/auth/attestation.py`, the attestation route, models, and
  migration `0005`: device attestation, request assertions, and replay defense
- `Backend/ladle/auth`, `Backend/ladle/api/routes/auth.py`, database models, and
  migration `0006`: Apple refresh-token lifecycle and permanent account removal
- App/unit/UI/backend tests covering each changed behavior

## TestFlight metadata draft

### Beta app description

Overeasy turns TikTok, Instagram, and YouTube recipe links into clear,
cook-friendly recipes. Save from the app or the iOS share sheet, review
ingredients and steps, use focused cooking mode and timers, and optionally
export a selected serving to Apple Health.

### What to test

1. Continue as a guest and import a supported public TikTok, Instagram, or
   YouTube recipe URL.
2. On a signed device, sign in with Apple and Google separately; also save a
   guest recipe before Google sign-in and confirm it remains available.
3. Share a supported recipe link to “Add to Overeasy” and confirm it appears in
   the import inbox after returning to the app.
4. Search, filter, favorite, edit, re-import, and delete recipes.
5. Open Watch, play the original source, and move among Overview, Ingredients,
   and Method.
6. Start Cooking, check ingredients and steps, enter Focus mode, and run a
   detected timer.
7. Open recipe options, review Nutrition, and test the optional Apple Health
   export.
8. Open Account, review Privacy & data, test sign-out, and inspect the permanent
   deletion confirmation.

### Beta review notes

- No username or password is required; choose **Try as a guest**.
- Apple Health is optional and is requested only from the explicit export flow.
- The share extension is named **Add to Overeasy**.
- Account deletion is available under **Account → Delete account**.

### Owner-supplied App Store Connect fields

- Feedback email: **required**
- Support URL: **required**
- Privacy policy URL: **required**
- App Store Connect app record for bundle ID `com.ladle.ios`
- Google Cloud OAuth clients: one iOS client for `com.ladle.ios` and one web
  client whose client ID is used as the server audience
- Build-time `GOOGLE_IOS_CLIENT_ID`, `GOOGLE_REVERSED_CLIENT_ID`, and
  `GOOGLE_SERVER_CLIENT_ID` values in
  `.private/GoogleAuth.xcconfig`, copied from
  `Config/GoogleAuth.xcconfig.example`
- Apple Developer team with App Store distribution signing for
  `com.ladle.ios`, `com.ladle.ios.share`, and `group.com.ladle.ios`
- App privacy answers matching imported URLs, recipe content, user/device IDs,
  diagnostics, and the absence of tracking/advertising

## Release blockers and upload handoff

The frontend candidate is locally green, but it must not be uploaded until all
of the following external release gates are closed:

1. Deploy the production API and worker, run migrations through `0011`, route
   `api.ladle.app` to them, and install a valid TLS certificate. Recheck both
   `/health/live` and `/health/ready` over HTTPS.
2. Inject the production database, Redis, object-storage, extraction-provider,
   signing, encryption, Sign in with Apple, and App Attest configuration
   documented in `Backend/.env.example` and the backend verification record.
3. Create the Google OAuth clients, add the reversed iOS client ID as the URL
   scheme, inject all three iOS values above, and set
   `LADLE_GOOGLE_ENABLED=true` plus `LADLE_GOOGLE_SERVER_CLIENT_ID` on the
   backend. The backend audience and iOS server client ID must be identical.
4. Run the paid-provider capability smoke tests with real credentials. These
   integrations were deliberately not represented as live when only local fake
   providers were available.
5. Configure the Apple Developer team for both Xcode targets and create
   distribution-capable App IDs/profiles for `com.ladle.ios`,
   `com.ladle.ios.share`, and `group.com.ladle.ios`, including Sign in with
   Apple, HealthKit, App Groups, and App Attest capabilities.
6. Install a valid Apple Distribution identity and run the production App
   Attest, Sign in with Apple, Sign in with Google, share-extension, import,
   guest-merge, and account-deletion journeys on a signed physical device. App
   Attest production validation cannot run in Simulator.
7. Create or confirm the App Store Connect app record, complete the owner fields
   above, archive with managed distribution signing, validate, upload, wait for
   processing, then attach the beta description, test notes, and review notes
   from this document.

The compile-only handoff artifact is
`/tmp/Overeasy-1.0-20260726.2-unsigned.xcarchive.zip` (13 MB,
SHA-256 `64010a9337aa85b6ee34b9a7aaf24bf28631c1a6d6ae9cb8a180d0c8b251c0a3`).
It was generated with explicit placeholder Google client IDs and proves the
generic Release device composition. It is intentionally unsigned, cannot be
installed, cannot perform Google sign-in, and cannot be uploaded to App Store
Connect.

## Verification record

| Check | Result |
| --- | --- |
| LadleCore tests | 37 passed |
| iOS Ladle scheme | 152 passed across app, unit, and UI coverage |
| Share renders | Loading, success, and failure passed render tests and visual inspection at standard and Accessibility sizes |
| Backend tests | 459 passed; 5 credential-gated tests intentionally deselected |
| Backend lint/type checks | Ruff format/check and mypy passed |
| Live Release API | Blocked: HTTPS TLS hostname rejected; HTTP serves a parked-domain page |
| Unsigned Release archive | Passed; app and extension are `1.0 (20260726.2)`, app and Google dependency privacy manifests plus both dSYMs are present |
| Signed Release archive | Blocked: only an Apple Development identity is installed; the project has no distribution team/profile configuration |
| Signed App Store export/upload | Blocked by the live API, missing real Google OAuth values, distribution signing, owner metadata, and App Store Connect access |
