# Watch feed TestFlight candidate

Date: August 23, 2026

## Purpose

Package the merged full-screen Watch feed for internal TestFlight testing using
the guarded VPS Release configuration.

## Candidate

- Marketing version: `1.0`
- Build: `20260823.3`
- Distribution: internal TestFlight only
- Backend: guarded VPS from `Config/Release.xcconfig`

## Included behavior

- Full-viewport vertical paging in Watch
- Stable per-session random ordering of saved video recipes
- Direct Play, Favorite, Share, Open Recipe, and Start Cooking actions
- Existing Discover, import, account, and Share Extension functionality

## Verification

- The Watch UI paging test passed on the iOS 26.5 simulator.
- All 26 `LibraryViewModelTests` passed.
- The Ladle app and embedded Share Extension built successfully before the
  TestFlight version bump.
- Archive validation and App Store Connect upload status are recorded after
  distribution completes.
