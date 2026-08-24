# Watch feed TestFlight candidate

Date: August 23, 2026

## Purpose

Package the merged full-screen Watch feed for internal TestFlight testing using
the guarded VPS Release configuration.

## Candidate

- Marketing version: `1.0`
- Build: `20260823.3`
- Source revision: `97c5284`
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
- The signed archive contains app and Share Extension build `20260823.3`, both
  dSYMs, the privacy manifest, and the guarded VPS API URL.
- App Store Connect accepted the internal-only upload at 11:54 PM EDT. Build
  `20260823.3` completed processing, entered `Testing`, and was assigned to the
  Internal Testers group with one invite.
