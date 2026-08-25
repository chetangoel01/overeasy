# Inline Watch playback

Date: August 25, 2026

## Purpose

Keep saved TikTok, Instagram, and YouTube videos inside the Watch experience.
Pressing Play must not present a browser or a browser-like sheet.

## User-visible behavior

- Play replaces the current recipe artwork with a bounded platform player in
  the same vertically paged Watch screen.
- The Watch title, close and account controls, recipe attribution and actions,
  and floating tab bar remain native and visible around the player.
- Closing the player restores the poster. Paging to another recipe removes the
  prior player, and backgrounding the app suspends its media.
- Provider links and unsupported main-frame navigations are cancelled. A saved
  URL without a supported video identifier shows an unavailable state instead
  of opening the original social page.

## Important decisions

- TikTok Player for Web, the YouTube IFrame player, and Instagram's reel/post
  embed are the supported playback surfaces. The providers do not offer Ladle
  a stable raw-media contract suitable for `AVPlayer`.
- Only the active recipe creates a web view. This preserves the native paging
  gesture and avoids keeping a player alive in every lazy feed cell.
- TikTok and Instagram use portrait stages; YouTube uses a 16:9 stage. The
  containing layout remains native SwiftUI in all cases.
- UI-test fixtures use deterministic order and live provider sample URLs so the
  no-browser flow can be exercised in the simulator. Production Watch ordering
  remains shuffled once per library session.

## Affected components

- `Ladle/Library/VideoEmbedSheet.swift`
- `Ladle/Library/WatchView.swift`
- `Ladle/App/LadleApp.swift`
- `Ladle/Data/PreviewFixtures.swift`
- `LadleTests/LibraryNavigationStateTests.swift`
- `LadleUITests/DiscoverInteractionUITests.swift`
- `DESIGN.md` and `README.md`

## Verification

- URL-contract regressions were written first and failed against the prior
  embed URLs and original-page fallback.
- `LibraryNavigationStateTests` verifies platform-player URLs for TikTok,
  YouTube, and Instagram and verifies that unsupported URLs never fall back to
  the browser page.
- `testWatchPlaysVideoInlineWithoutOpeningSafari` taps Watch Play, finds the
  in-app web view and native close control, confirms Ladle remains foregrounded,
  and confirms Mobile Safari is not foregrounded.
- The iPhone 17 Pro simulator screenshot was visually inspected at 402 by 874
  points. The TikTok player and its controls remain inside Watch with Ladle's
  surrounding controls and recipe actions visible.
- The live TikTok Player for Web, YouTube embed, and Instagram reel embed used
  by the fixtures each returned HTTP 200 during verification.
- The focused unit and no-Safari UI tests pass on the iPhone 17 Pro iOS 26.5
  simulator. The `Ladle` scheme builds successfully and its embedded,
  code-signed `LadleShare.appex` contains an arm64 simulator executable.
- `git diff --check` passes after the documentation update.
