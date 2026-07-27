# Import continuity and dark mode

## Purpose

Make video imports durable and recoverable without blocking later saves, keep
import state out of the way when it is no longer useful, prevent incomplete
recipes from entering cooking mode, and give every app and Share Extension
surface one coherent light/dark visual system.

## User-visible behavior

- Imported thumbnails are copied into a private MinIO bucket instead of
  depending on expiring social-provider URLs. Existing cached thumbnails are
  backfilled during deployment.
- A rejected refresh token signs the user out instead of appearing as an
  internet outage. Any interrupted local import becomes a durable failed item
  with recovery actions instead of remaining in a parsing state forever.
- Import Inbox appears on Home only while an import is parsing or needs
  attention. It scrolls away with Home content, has no close control, and
  dismisses its destination when the last actionable item is resolved.
- Inbox rows explain the specific failure and support native trailing
  swipe-to-delete.
- A recipe that needs review can be marked reviewed from recipe detail. That
  clears both the recipe warning and its normal import-inbox item.
- A pending re-import review remains saved but no longer prevents starting a
  different import.
- Search, Import Inbox, Watch, and recipe detail use native navigation bars,
  restoring the system left-edge swipe-back gesture. Search, Import Inbox, and
  Watch also share one exclusive destination value so a stale Watch route
  cannot capture an Inbox tap.
- Share confirmation remains visible after success or failure until the user
  taps **Done**. It has no competing close icon.
- Welcome is fixed in place at standard text sizes and scrolls only when
  accessibility text requires the additional height.
- The app and Share Extension follow the system appearance with a warm dark
  palette. SF Rounded remains limited to display roles; body, metadata, and
  cooking instructions use the system text design.
- Accent text uses an appearance-aware paprika token while brick remains a
  fixed button fill. Focus Mode uses a fixed plum foreground on its fixed light
  action surface, preserving contrast in both appearances.
- Home, Welcome, Import Inbox, recipe detail, Watch, cooking, and Share
  confirmation remove redundant eyebrow labels, helper sections, counts, and
  repeated headings. Each screen keeps one primary title and only the labels
  needed to navigate or act.
- A recipe that still needs review, ingredients, or a method cannot enter
  cooking mode. Watch sends it to review, and recipe detail points the user to
  review or editing. Unknown imported yield is shown as unknown, not as
  “1 servings,” and Watch discloses when its preview omits remaining items.
- When source evidence clearly identifies a dish and its core ingredients,
  extraction may bridge a practical method from general cooking knowledge. It
  must label that method partial or inferred and cannot invent quantities,
  timing, temperature, or creator claims. This is bounded inference, not live
  web lookup.

## Important decisions

- Acquisition carries the metadata provider's thumbnail through extraction.
  The pinned, public-address-only downloader copies it into the private bucket.
  The Mac mini profile keeps MinIO off host ports, allows worker access only on
  its internal object-storage port, and emits short-lived signed read URLs
  through the ngrok listener.
- Deployment runs an idempotent legacy backfill that replaces matching remote
  locations in both extraction caches and recipe images. A copy failure leaves
  that row unchanged so deployment can retry it later without losing the
  current image reference.
- Migration `0012` lets an extraction cache use at most one thumbnail
  location: an object key or a remote URL.
- Review completion saves the recipe and related import jobs in one SwiftData
  transaction. Re-import candidates remain isolated until their existing
  accept/keep decision is made.
- Native `List` swipe actions own inbox deletion, and native navigation owns
  back behavior. No custom gesture competes with either convention.
- Dynamic asset-catalog variants own app appearance. A fixed warm
  `onAccent` token keeps text and symbols legible on brick, plum, and success
  fills in both appearances. A separate adaptive accent token is used for
  text, symbols, progress controls, and errors.
- Cooking readiness is a shared domain rule rather than a view-only check, so
  every entry point uses the same minimum requirements.

## Affected components

- Backend acquisition, thumbnail orchestration and backfill, MinIO, Nginx,
  ngrok policy, extraction cache, template cloning, prompt version
  `recipe-2026-07-27-v8`, and Alembic revision `0012`
- `ImportCoordinator`, `LibraryViewModel`, SwiftData repository, Import Inbox,
  Home, Search, Watch, and recipe detail
- `APIClient`, `AccountSession`, `Recipe` cooking readiness, Welcome, Share
  Extension confirmation, design tokens, asset colors, editor, filters,
  recovery, Health export, and cooking surfaces

## Verification

- Ruff and strict mypy checks pass. The complete backend suite passes 476
  tests with five intentional skips.
- All 40 LadleCore tests pass.
- The complete app unit target passes 144 tests with one intentional skip.
  Coverage includes import deletion, atomic review completion, non-blocking
  re-import review, failure copy, welcome layout, explicit share dismissal,
  and light/dark token and Share Extension rendering.
- Eight targeted UI scenarios pass, including readable failed-import context,
  swipe deletion, upward hide/downward reveal, the native edge-back gesture,
  Search, Watch, and the fixed Welcome layout.
- Dark Home, hidden-inbox Home, and Import Inbox screenshots were inspected at
  402 × 874 points. The warm surfaces, display/body type roles, contrast,
  row wrapping, and native navigation remain legible without clipping.
- The full simulator app build succeeds and validates the embedded
  `LadleShare.appex`.
- Mac mini deployment commit `13ac0b6` is healthy at migration `0012`.
  A real Instagram import through the keyed ngrok route completed as
  `needsReview`, and recipe retrieval returned one HTTPS thumbnail. The
  temporary guest account was then deleted successfully.
- Release build `1.0 (20260727.1)` passed strict signature verification for
  the app and embedded Share Extension. Both contain the shared
  `P48VDW72LU.com.ladle.shared` Keychain entitlement, and the build installed
  successfully on the paired iPhone.
- The packaged device artifact is
  `/tmp/Overeasy-1.0-20260727.1-import-dark-mode.ipa`; ZIP validation passes,
  the Share Extension binary is present, and its SHA-256 is
  `a4c18c1e08974cf2b2ce7c1d48afc138c65bcd7301b6bc58e07f4e0a3486de96`.

### Current replacement build

- `swift test --package-path Packages/LadleCore` passes all 42 tests.
- The complete `LadleTests` target passes 150 tests with one intentional live
  App Attest skip and zero failures. Focused coverage includes rejected-token
  sign-out, durable terminal import failures, exclusive Library workspace
  navigation, cooking readiness, contrast tokens, and reduced heading
  hierarchy.
- The backend thumbnail/deployment regressions pass, along with targeted Ruff,
  strict mypy, shell syntax, and merged Compose configuration checks.
- Per the user's direction, no UI test target was run. A manual Simulator
  launch inspected the revised dark empty-Home hierarchy, typography, action
  contrast, and fixed standard-size layout.
- Release build `1.0 (20260727.2)` succeeds for the paired iPhone and includes
  the Share Extension. Strict signature verification passes, both binaries
  contain `P48VDW72LU.com.ladle.shared`, the embedded ngrok endpoint and tunnel
  key match the live route, and App Attest is explicitly disabled for this
  Personal Team development backend.
- The build installed successfully on the paired iPhone. Automatic launch was
  deferred because the device locked after installation.
- `/tmp/Overeasy-1.0-20260727.2-thumbnail-import-fixes.ipa` passes ZIP
  validation and contains the Share Extension binary. Its SHA-256 is
  `406eca12005bc7db8ccebdca4e09526f1b66aa20dfe028608e5227a979b52309`.
