# Inline Watch playback

Date: August 25, 2026

## Purpose

Keep saved TikTok, Instagram, and YouTube videos inside the Watch experience.
Entering Watch must present the active provider player without a separate Ladle
Play step or a browser-like sheet.

## User-visible behavior

- The visible recipe starts with a full-bleed platform player in the vertically
  paged Watch screen. A provider may still require its own first Play gesture.
- The Watch title, Pause or Resume, Mute or Unmute, and account controls, recipe
  attribution and actions, and floating tab bar remain native and visible over
  the player. Top and bottom scrims keep that chrome readable without shrinking
  the video.
- Mute state follows the user across recipes. Paging removes and suspends the
  prior player; backgrounding the app suspends the active player.
- Provider links and unsupported main-frame navigations are cancelled. A saved
  URL without a supported video identifier shows an unavailable state instead
  of opening the original social page.

## Important decisions

- TikTok Player for Web, the YouTube IFrame player, and Instagram's reel/post
  embed are the supported playback surfaces. The providers do not offer Ladle
  a stable raw-media contract suitable for `AVPlayer`.
- Only the active recipe creates a web view. This preserves the native paging
  gesture and avoids keeping a player alive in every lazy feed cell.
- Pause and Resume use WebKit's reversible media suspension. Mute and Unmute use
  a small all-frame media bridge so the same controls work across the supported
  provider embeds without navigating away from Watch.
- Every provider owns the full viewport and preserves its own media aspect
  treatment. TikTok's redundant transport controls are hidden individually so
  its center Play and engagement rail remain without colliding with recipe
  actions.
- The embedded web view disables its own scrolling. Taps still reach provider
  playback controls, while an upward drag continues to page the native Watch
  feed and removes the prior player.
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
- `testWatchDefaultsToInlinePlayerWithPlaybackControls` enters Watch and finds
  the in-app player without tapping a Ladle Play button, confirms it matches the
  full app frame, exercises Pause or Resume and Mute or Unmute, confirms Mobile
  Safari is not foregrounded, and verifies that an upward swipe advances to a
  different recipe.
- The iPhone 17 Pro simulator screenshot was visually inspected at 402 by 874
  points. The TikTok player is the default edge-to-edge Watch surface; native
  Pause or Resume, Mute or Unmute, recipe actions, and the tab bar remain
  legible over the video. A dark loading surface prevents a white provider-page
  flash before the embed finishes loading.
- The live TikTok Player for Web, YouTube embed, and Instagram reel embed used
  by the fixtures each returned HTTP 200 during verification.
- The focused unit and no-Safari UI tests pass on the iPhone 17 Pro iOS 26.5
  simulator. The `Ladle` scheme builds successfully and its embedded,
  code-signed `LadleShare.appex` contains an arm64 simulator executable.
- `git diff --check` passes after the documentation update.
