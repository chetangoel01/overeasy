# Import continuity and dark mode

## Purpose

Make video imports recoverable without blocking later saves, keep import state
out of the way when it is no longer useful, and give every app and Share
Extension surface one coherent light/dark visual system.

## User-visible behavior

- Imported videos keep their provider thumbnail even when the Mac mini staging
  profile runs without object storage.
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
  restoring the system left-edge swipe-back gesture.
- Share confirmation remains visible after success or failure until the user
  taps **Done**. It has no competing close icon.
- Welcome is fixed in place at standard text sizes and scrolls only when
  accessibility text requires the additional height.
- The app and Share Extension follow the system appearance with a warm dark
  palette. SF Rounded remains limited to display roles; body, metadata, and
  cooking instructions use the system text design.
- When source evidence clearly identifies a dish and its core ingredients,
  extraction may bridge a practical method from general cooking knowledge. It
  must label that method partial or inferred and cannot invent quantities,
  timing, temperature, or creator claims. This is bounded inference, not live
  web lookup.

## Important decisions

- Acquisition carries the metadata provider's thumbnail through extraction.
  With object storage, the existing pinned, public-address-only downloader
  copies it into the private bucket. Without object storage, an HTTPS provider
  URL is retained in the extraction cache and recipe image graph.
- Migration `0012` lets an extraction cache use at most one thumbnail
  location: an object key or a remote URL.
- Review completion saves the recipe and related import jobs in one SwiftData
  transaction. Re-import candidates remain isolated until their existing
  accept/keep decision is made.
- Native `List` swipe actions own inbox deletion, and native navigation owns
  back behavior. No custom gesture competes with either convention.
- Dynamic asset-catalog variants own app appearance. A fixed warm
  `onAccent` token keeps text and symbols legible on brick, plum, and success
  fills in both appearances.

## Affected components

- Backend acquisition, thumbnail orchestration, extraction cache, template
  cloning, prompt version `recipe-2026-07-27-v8`, and Alembic revision `0012`
- `ImportCoordinator`, `LibraryViewModel`, SwiftData repository, Import Inbox,
  Home, Search, Watch, and recipe detail
- Welcome, Share Extension confirmation, design tokens, asset colors, editor,
  filters, recovery, Health export, and cooking surfaces

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
