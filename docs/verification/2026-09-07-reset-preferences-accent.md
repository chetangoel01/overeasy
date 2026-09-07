# `-reset-library-preferences` starts from the stock accent again

Date: September 7, 2026
Issue: [#71](https://github.com/chetangoel01/recipe-app/issues/71)
Status: **fixed, and verified on the review simulator.**

## Purpose

`-reset-library-preferences` exists so a UI run or a review capture starts
from a known library presentation and a known accent. It did not: launching
with `-ui-testing -onboarding-complete -reset-library-preferences` after
pinning Sage came up green, and the pinned value was still there afterwards.

Two things were wrong, and neither was the one the issue guessed at.

## Root cause

**The reset removed the accent from a domain the seeded value was not in.**
`UserDefaults.removeObject(forKey:)` only clears the app's *own* preference
domain. The way an accent gets pinned for a capture —

```
xcrun simctl spawn <udid> defaults write com.ladle.ios \
  ladle.appearance.accent-color sage
```

— does not write there. It writes the simulator's device-level domain,
`<device>/data/Library/Preferences/com.ladle.ios.plist`. The app *reads*
through to that file but cannot delete from it, so after a reset the seeded
value was still what `string(forKey:)` returned. Measured in the running app:

```
DIAG before accent=Optional("sage")
DIAG reset branch entered
DIAG after accent=Optional("sage")
```

The same launch with the accent held in the app's own domain cleared
correctly (`DIAG after accent=nil`) — which is why the bug looked
intermittent and unexplainable.

The app's own domain *outranks* the seeded one, so writing the default wins
where removing it does not. Measured the same way: with `sage` seeded
device-level, the app writing `blue` made `string(forKey:)` return `blue`.

**The reset also ran after the first frame.** It lived in `LadleRuntime.init`,
which `AppBootstrap.run()` reaches, which `LadleApp` calls from a `task` on
the window — i.e. after `@AppStorage(LadleAccentColor.preferenceKey)` had
already been read for the first render. Even when the removal worked, the
launch opened on the old accent and then snapped. It also re-ran on every
`retryBootstrap()`, and the flag describes a launch, not an attempt.

## What changed

- `LibraryViewModel.resetPreferences(in:)` **writes the defaults** instead of
  removing the keys: grid display mode, both collapse flags off, inbox
  dismissal off, `tomato` accent. A value seeded outside the app's domain is
  now overridden rather than left showing.
- The reset moved from `LadleRuntime.init` to `AppBootstrap.init`, which
  `LadleApp.init()` runs — the last point that is still before anything reads
  a preference. `AppBootstrap` takes an injectable `PreferenceStoring` so this
  is testable without touching the real defaults.
- `LadleRuntimeConfiguration.resetsLibraryPreferences` names the flag beside
  the other launch-argument readers instead of a bare `contains` in the
  runtime.

`ladle.library.inbox-dismissed` is still in the list. No code reads it any
more, but a container that ran an older build still carries it, so the reset
keeps clearing it. Removing it is a separate cleanup.

## Two things the issue reported that do not reproduce

- **`-empty-library` works.** A genuinely fresh launch of
  `-ui-testing -onboarding-complete -empty-library` comes up with no Inbox
  badge — the seeded demo imports are absent. The issue's contrary
  observation was almost certainly a `simctl launch` onto an already-running
  process, which re-foregrounds the old `argv`; `--terminate-running-process`
  avoids it.
- **The launch arguments do arrive.** Verified directly:
  `-ui-testing -onboarding-complete -demo-scenario store-failure` reaches the
  bootstrap and shows `OE-BOOT-STORE-001`, so a flag in third and fourth
  position is read. The issue's "`NSArgumentDomain` is eating the flags" lead
  is dead.

## A trap for whoever debugs preferences here next

`xcrun simctl spawn <udid> defaults read com.ladle.ios` does **not** show the
app's own preference domain. It reads the device-level plist. The app's own
domain is the container's:

```
xcrun simctl get_app_container <udid> com.ladle.ios data
plutil -p "<that path>/Library/Preferences/com.ladle.ios.plist"
```

or, from inside the app, `UserDefaults.standard.persistentDomain(forName:)`.
The two files disagree, and reading only the first one is what made the
original investigation conclude the reset "never ran at all".

Note that after a fixed launch, `spawn defaults read` will still show the
seeded `sage`. That is expected and harmless — the app cannot delete from
that domain, it now writes over it. Judge the fix by the screen and by the
app's own domain, not by that file.

## Affected components

| File | Change |
|------|--------|
| `Ladle/Library/LibraryViewModel.swift` | `resetPreferences(in:)` writes the defaults instead of removing the keys; documents why |
| `Ladle/App/AppBootstrap.swift` | `AppBootstrap.init` takes a `PreferenceStoring` and performs the reset; the block is gone from `LadleRuntime.init` |
| `Ladle/App/LadleApp.swift` | `LadleRuntimeConfiguration.resetsLibraryPreferences` |
| `LadleTests/LibraryViewModelTests.swift` | new: the reset writes `tomato` rather than removing the key |
| `LadleTests/AppBootstrapTests.swift` | new: the reset lands in the constructor, before `run()` |

## Verification

### The tests

Written first, and red for the right reasons:

```
AppBootstrapTests.swift:197: error: … testResetLibraryPreferencesLandsBeforeTheBootstrapRuns :
  XCTAssertEqual failed: ("Optional("sage")") is not equal to ("Optional("tomato")")
LibraryViewModelTests.swift:514: error: … testResetPreferencesWritesTheDefaultAccentRatherThanRemovingIt :
  XCTAssertEqual failed: ("nil") is not equal to ("Optional("tomato")")
```

`testResetLibraryPreferencesLandsBeforeTheBootstrapRuns` asserts *without
calling `run()`*, which is the whole point: `run()` happens after the first
frame, so a reset only observable there is a reset that arrives too late.

Green after the change:

```
xcodebuild test -scheme LadleAllTests \
  -destination 'id=614AF85D-84AF-4371-BF70-5D5DA2BBA683'
```

- LadleTests: `Executed 463 tests, with 1 test skipped and 0 failures (0 unexpected) in 11.018 (13.241) seconds`
- LadleUITests: `Executed 28 tests, with 0 failures (0 unexpected) in 457.795 (457.843) seconds`
- `** TEST SUCCEEDED **`

The run reached its results and exited on its own this time; it was still
wrapped in a watchdog, because `xcodebuild test` has hung after printing
results on this machine before.

`swift test --package-path Packages/LadleCore` was not run: the package is
untouched.

### On the simulator

"Overeast UI validation" (`614AF85D-84AF-4371-BF70-5D5DA2BBA683`, iPhone 17
Pro, iOS 26.5), Debug build, each launch with
`--terminate-running-process` so no launch inherits an earlier `argv`.

```
xcrun simctl spawn <udid> defaults write com.ladle.ios ladle.appearance.accent-color sage
xcrun simctl launch --terminate-running-process <udid> com.ladle.ios \
  -ui-testing -onboarding-complete -reset-library-preferences
```

| | |
|---|---|
| [before-sage-survives.png](captures/2026-09-07-reset-preferences-accent/before-sage-survives.png) | the bug: green tab tint, green profile glyph, green creator handles |
| [after-brick-restored.png](captures/2026-09-07-reset-preferences-accent/after-brick-restored.png) | the same launch after the fix: brick throughout |

The accent held in the app's own domain was checked too, by having a
diagnostic build write `sage` through `UserDefaults.standard` on one launch
and reading it back on the next. Both paths end on brick.
