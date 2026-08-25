# Discover, feed, and import-confidence update

Date: August 23, 2026

## Purpose

Reduce routine recipe-verification work, make creator accounts visible in the
video and import surfaces, replace Watch paging with ordinary scrolling, add a
useful Discover destination, and finish the repository side of Apple and Google
sign-in configuration.

## Signed-in account presentation

- The Account sheet leads with the connected provider and an explicit sync
  status instead of the ambiguous "Signed in as Google account" label.
- Library status shows saved-recipe count and whether sync is on. The internal
  installation identifier is no longer exposed to users.
- Privacy remains one clear destination, while sign-out and permanent deletion
  are compact secondary actions with their existing confirmations.
- Provider identity stays intentionally limited to Apple or Google. The app
  does not add storage for profile names, email addresses, or avatars.

## User-visible behavior

- Recipes, Discover, Watch, and Inbox are persistent native workspace tabs.
  Recipes keeps search, sort, filters, display controls, and generated
  collections in one archive rather than splitting them across Home and All.
- Discover ranks public social-recipe sources by aggregate saves from other
  accounts. Rows show creator account, source image, summary, save count, and a
  Save action that stores the already-resolved recipe immediately. Sources
  already saved by the current account are excluded, and a newly saved row
  leaves the feed when the request completes.
- Tapping a Discover result loads its complete shared recipe and pushes a
  read-only detail screen without saving it. A long press previews Discover and
  saved recipes with native Open and Save/Favorite context-menu actions.
- Account management is the consistent top-right action on Recipes, Discover,
  Watch, Inbox, and saved or Discover recipe details. Add Recipe remains limited
  to Recipes; distraction-free Focus Mode remains intentionally unchanged.
- Watch uses continuous native scrolling and content-sized cards. It no longer
  snaps one viewport-sized card at a time.
- Watch and Import Inbox show the source creator account when available. Inbox
  also derives handles such as `@cook` from supported source URLs while an
  import is still processing.
- The former routine "Needs review" presentation is now "Check details" and is
  exceptional. Reconstructed standard methods and labeled serving estimates do
  not block cooking. A recipe is gated only when most non-garnish ingredients
  remain without usable amounts.

## Import decisions

- Prompt version `recipe-2026-08-23-v10` permits conservative conventional
  ingredient estimates when dish context and standard technique support them.
- Estimated quantities use rounded measures, confidence below 0.7, and a short
  cook-facing uncertainty reason. The prompt forbids presenting an estimate as
  the creator's stated amount.
- A missing yield falls back to a clearly labeled four-serving household
  estimate only when ingredient mass cannot support a better calculation.
- Nutrition without an explicit basis remains per-serving instead of being
  divided again by the recipe yield.

## Discovery privacy

`GET /v1/recipes/discover` groups ready, undeleted social recipes by their
normalized source-video record and ranks them by distinct saving accounts. The
response is rebuilt from the shared extraction cache and contains public source
metadata plus an aggregate count only. It excludes account IDs, private
ingredients and steps, user edits, correction notes, and sources already saved
by the requesting account. Saving uses the opaque source ID to instantiate the
ready shared extraction as a new account-owned recipe. It does not copy another
user's recipe and does not create an import job, download media, transcribe
audio, or call an extraction model. Repeated save requests return the same
active account recipe.

## Authentication configuration

The app contains the Apple entitlement and native authorization-code / nonce
flow, plus the Google iOS SDK, callback URL scheme, server-audience token
exchange, backend verification, and guest-account merge. The provider consoles
and local runtime are now configured:

- Apple Developer has Sign in with Apple enabled for `com.ladle.ios`. The
  `Ladle Sign In` key is scoped to that primary App ID.
- Google Cloud project `ladle-recipe-app-2026` has external production consent
  branding plus separate iOS and backend OAuth clients. The iOS client is bound
  to bundle ID `com.ladle.ios` and team `P48VDW72LU`; no Web origins or redirect
  URIs are needed for backend ID-token audience verification.
- `.private/GoogleAuth.xcconfig` supplies the iOS, reversed, and server client
  IDs. `Backend/.env` enables both providers and points Apple at the downloaded
  private key.
- Both local configuration files and the Apple `.p8` are ignored by Git and
  restricted to owner read/write permissions. The unused Google Web client
  secret was not stored.

A signed physical-device pass remains required before release for Apple,
Google, guest merge, refresh, account deletion, and regenerated provisioning
profiles.

## Affected components

- `Backend/ladle/extraction/prompt.py` and `review.py`
- `Backend/ladle/api/routes/recipes.py`, recipe contracts, repository, and service
- `Packages/LadleCore/Sources/LadleCore/RemoteContracts.swift`
- `Ladle/Library/DiscoverView.swift`, `WatchView.swift`, and inbox presentation
- `Ladle/Account/AccountSheet.swift`
- `Ladle/Remote/DiscoverService.swift`
- Root composition and the existing import sheet

## Verification

- Prompt/review unit tests cover labeled estimation and exceptional gating.
- Discover API integration coverage proves aggregation and response privacy.
- Discover direct-save coverage proves idempotent cloning, sync visibility, and
  zero import-job creation.
- Discover detail coverage proves the full shared ingredients and method can be
  read without creating an account recipe.
- LadleCore contract coverage decodes the Discover wire payload.
- App tests cover Discover loading/error states, save idempotency, creator
  attribution, and account toolbar availability across all workspace tabs.
- A focused simulator UI test performs a real 0.8-second press on a Discover
  result, verifies the native View/Save menu, opens the preview, and confirms
  Account remains available from the detail screen.
- `swift test --package-path Packages/LadleCore`: 44 passed.
- Full simulator test suite: 175 passed, 1 skipped, 0 failures.
- Backend suite: 520 passed, 5 skipped.
- A generic iOS Simulator build completed for the app and embedded Share
  Extension with `CODE_SIGNING_ALLOWED=NO`.
- Runtime settings load the Apple private key and both enabled provider
  configurations without exposing credential contents.
- Focused Apple, Google, and production-configuration tests: 72 passed.
- A post-configuration simulator build confirms the issued iOS client ID,
  server audience ID, and callback scheme are embedded in the app.
- A signed generic-device build succeeded with regenerated automatic
  provisioning for the app and Share Extension.
- The local Compose contract forwards both provider configurations and mounts
  the Apple private key read-only into the API container.
- On the dedicated `Ladle-Verify` iOS 26.5 simulator, Apple opened the system
  Apple Account prompt. Full token exchange requires signing that simulator
  into an Apple Account.
- The same simulator completed Google OAuth through `accounts.google.com`; the
  local API accepted `/v1/auth/google` with `200 OK`, restored the signed-in
  session, and loaded the live Discover feed.
- Google App Check prewarm failure was reproduced red on the simulator, fixed
  as a non-blocking optimization, and protected by a focused regression test.
- The signed-in Account sheet was visually checked on `Ladle-Verify` after a
  successful Google session; all content fit without clipping, and the focused
  provider/sync presentation test passed.
- Earlier consolidation checkpoint: 167 iOS tests passed on `Ladle-Verify` with
  one expected skip; LadleCore passed 44 tests; the backend suite passed 518
  tests with five expected skips.
- The Porcelain & Graphite redesign was inspected on the same simulator after
  consolidation. Recipes, Discover, and regular-scroll Watch retained native
  hierarchy, four-tab navigation, and readable creator attribution.
