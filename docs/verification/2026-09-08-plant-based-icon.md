# An icon without the egg, offered once

Date: September 8, 2026
Branch: `feat/plant-based-icon`
Issue: [#92](https://github.com/chetangoel01/recipe-app/issues/92)
Status: **built and verified on a simulator created for the run.**

## Purpose

The note said "change the logo". The reason behind it is the interesting
part: the app is named after an egg, and a vegetarian or vegan cook should
not have to carry one on their home screen. So the alternate icon is a
product point rather than decoration, and the shape of the feature follows
from that — the app *asks*, once, and never switches anything by itself.

## The artwork is a placeholder

`AppIcon-PlantBased.appiconset` holds the **Bowl candidate from
[#114](https://github.com/chetangoel01/recipe-app/pull/114) exactly as it
was rendered** (`design/board/icon-candidates/02-bowl.png`, 1024×1024,
copied byte for byte, not redrawn). It is a placeholder: the real
plant-based direction is still being chosen, and replacing it is replacing
one PNG — plus its drawable twin, below. Nothing else in this change moves
with the artwork, which is why the set is named for what it *is* rather
than for what is currently drawn in it.

## What the cook sees

- **Two icons.** The egg the app shipped with, and one plant-based
  alternate. No per-accent variants.
- **A picker in Profile, under Appearance.** Two tiles, the installed one
  ringed and checked in the cook's accent. It is deliberately independent of
  the diet: a cook who eats everything may still prefer the bowl, and a
  vegan who likes the egg keeps it. Either way, at any time.
- **One question, once.** When the stored diet first includes vegetarian or
  vegan, the app asks "Prefer an icon without the egg?" — *Use it* or *Keep
  the egg* — and never asks again. It is asked where the answer that raised
  it was given: in Profile when the diet is changed there, on the library
  when the diet came from onboarding.
- **Nothing changes on its own.** The offer only raises the question. A cook
  who keeps the egg keeps it, and a cook already carrying the bowl is not
  asked about it at all.
- **iOS confirms the change itself** — "You have changed the icon for
  Overeasy" — and that notice is left alone. The picker adds no confirmation
  of its own in front of it; a second alert would only be the app asking
  whether the cook meant the tap they had just made.

## How the offer is gated

`AppIconStore.offerIfNeeded(for:)` is the whole rule, and every clause of it
is a decision:

| Clause | Why |
|---|---|
| `application.supportsAlternateIcons` | a device that cannot change its icon is never asked about it |
| `icon == .egg` | nobody is offered what they are already carrying; their question is left unspent for whenever they go back |
| `diets.contains(.vegetarian) \|\| diets.contains(.vegan)` | pescatarian, gluten-free and dairy-free cooks eat eggs |
| `!preferenceStore.bool(forKey: "ladle.appearance.plant-based-icon-offered")` | once, ever |

The flag is written **when the question is shown**, not when it is answered:
an app that dies with the alert up has still asked. `-reset-library-preferences`
writes it `false` — written, not removed, for the same reason the accent is
written (a value seeded into the simulator's device-level domain by `simctl
spawn defaults write` is read through but cannot be deleted from the app's
own domain). The *installed icon* is not reset with it: that belongs to the
home screen, not to our preferences.

Two views call it, because the diet is set in two places:

- `AccountSheet` — `.onChange(of: library.filters.diets)`. The diet menu
  lives under the cook's name in this sheet, so the question follows the tap
  that raised it.
- `LibraryView` — `.task`. A diet answered at onboarding is written before
  the library exists, so there is no change here to notice; the question is
  put when the cook lands in the app. This also means an existing
  vegetarian cook is asked once on the first launch after updating, which
  is what "when the stored diet first includes vegetarian or vegan" means
  for a library that already has one.

One alert, though, not two: `plantBasedIconOffer(_:isEnabled:)` is attached
in both places and the library's copy stands down while Profile is open, so
whichever view is in front is the one that asks.

## The asset and plist mechanics

`project.yml` declares the alternate on the `Ladle` target:

```yaml
ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES: AppIcon-PlantBased
```

That one line is the whole declaration. `actool` compiles the set and writes
the entry into its partial `Info.plist`, which is merged into the manually
maintained `Config/Ladle-Info.plist` — no `CFBundleIcons` is hand-written.
Measured in the built app:

```
CFBundleIcons
  CFBundlePrimaryIcon   → CFBundleIconName AppIcon,   CFBundleIconFiles [AppIcon60x60]
  CFBundleAlternateIcons
    AppIcon-PlantBased  → CFBundleIconName AppIcon-PlantBased
```

`setAlternateIconName("AppIcon-PlantBased")` looks the name up there;
`nil` goes back to the egg. The share extension is untouched — it has no
home-screen icon to change.

### Why each icon has a twin in an `imageset`

The picker draws its tiles from `OvereasyMark` and
`OvereasyMarkPlantBased`, not from the icon sets. An `appiconset` is
compiled into `Assets.car` as an *icon* rather than an image, and
`UIImage(named: "AppIcon-PlantBased")` does not find it — measured, and
still nil with `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` on, which
writes loose files only for the primary icon's synthesised sizes. The egg
already had exactly this twin (`OvereasyMark`, byte-identical to
`AppIcon.png`, used by Welcome and the walkthrough); the plant-based icon
now has one too.

`ProjectSmokeTests.testEachAppIconKeepsADrawableTwinWithTheSameArtwork`
compares the two pairs byte for byte, because the failure mode of replacing
the placeholder in one set and not the other is a picker quietly offering
yesterday's icon.

## Affected components

| File | Change |
|------|--------|
| `Ladle/Resources/Assets.xcassets/AppIcon-PlantBased.appiconset` | new: the placeholder Bowl artwork, single 1024 iOS icon |
| `Ladle/Resources/Assets.xcassets/OvereasyMarkPlantBased.imageset` | new: the same PNG, as something the picker can draw |
| `project.yml`, `Ladle.xcodeproj` | `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, regenerated |
| `Ladle/Design/AppIconStore.swift` | new: `LadleAppIcon`, `AlternateAppIconSetting`, `AppIconStore`, and the offer alert as a `View` modifier |
| `Ladle/Account/AccountSheet.swift` | the App icon section, and the offer where the diet is changed |
| `Ladle/Library/LibraryView.swift` | owns the store, and asks the question for the onboarding path |
| `Ladle/Library/LibraryViewModel.swift` | `-reset-library-preferences` writes the offer flag false |
| `LadleTests/AppIconStoreTests.swift` | new: 13 tests over the store and the gate |
| `LadleTests/ProjectSmokeTests.swift` | new: the alternate is in the bundle; the twins match |
| `LadleUITests/ProfileSheetUITests.swift` | new: the picker switches both ways; the Profile diet raises the offer |
| `LadleUITests/RecipesFilterMenuUITests.swift` | the onboarding diet raises the offer on the way in |

## Verification

### The tests, red first

`ProjectSmokeTests.testPlantBasedAlternateIconIsDeclaredInTheBundle` before
the declaration existed:

```
ProjectSmokeTests.swift:241: error: … XCTUnwrap failed: expected non-nil value of type "Dictionary<String, Any>"
```

and after the set was added but before the tiles had anything to draw:

```
ProjectSmokeTests.swift:254: error: … XCTAssertNotNil failed - The egg tile has nothing to draw
ProjectSmokeTests.swift:258: error: … XCTAssertNotNil failed - The plant-based tile has nothing to draw
```

`AppIconStoreTests` against a store whose methods were still empty — 12 of
13 red, for the right reasons:

```
AppIconStoreTests.swift:22:  … XCTAssertEqual failed: ("[]") is not equal to ("[Optional("AppIcon-PlantBased")]")
AppIconStoreTests.swift:110: … XCTAssertEqual failed: ("false") is not equal to ("true") - vegetarian was handled the wrong way
AppIconStoreTests.swift:220: … XCTAssertEqual failed: ("Optional(true)") is not equal to ("Optional(false)") - The flag has to be written false, not taken away
```

### Green

```
xcodebuild test -scheme LadleAllTests \
  -destination 'id=1653956E-76A4-46CB-ADF2-833DAA8CBA76'
```

The whole scheme, not only the suites this touches — the picker changed the
shape of the Profile form, and the offer now interrupts two flows that were
about the diet.

- LadleTests: `Executed 543 tests, with 1 test skipped and 0 failures (0 unexpected) in 7.586 (7.854) seconds`
- LadleUITests: `Executed 36 tests, with 0 failures (0 unexpected) in 600.577 (600.628) seconds`
- `** TEST SUCCEEDED **`

One existing UI test went red on the way and was fixed rather than
loosened: `testProfileHasNoExplanatoryFooters` asserted that the Privacy
and Account footers were absent, and the icon picker pushed both sections
below the fold, where a `Form` renders nothing at all. It scrolls to them
now.

The two diet UI tests that now walk through the offer were run on their own
first — `ProfileSheetUITests.testTheDietIsChangedBesideTheNameAndTheLibraryFollows`
and `RecipesFilterMenuUITests.testADietChosenDuringOnboardingIsAlreadyOnEveryTab`:
`Executed 2 tests, with 0 failures (0 unexpected) in 35.095 seconds`.

`xcodebuild build -scheme Ladle` (app plus share extension): `** BUILD SUCCEEDED **`.

`swift test --package-path Packages/LadleCore` was not run: the package is
untouched.

### On the simulator

`Ladle-icon-92` (`1653956E-76A4-46CB-ADF2-833DAA8CBA76`, iPhone 17 Pro,
iOS 26.5), created for this run and deleted after it.

| | |
|---|---|
| [offer.png](captures/2026-09-08-plant-based-icon/offer.png) | the question, once, after answering "vegetarian" at onboarding |
| [picker.png](captures/2026-09-08-plant-based-icon/picker.png) | the picker in Profile, under Appearance, with the plant-based icon installed |

The home screen, before and after the switch — the same device, the same
install, photographed with `xcrun simctl io <udid> screenshot` after the app
was terminated:

| Egg | Plant-based |
| --- | --- |
| ![Egg](captures/2026-09-08-plant-based-icon/home-egg.png) | ![Plant-based](captures/2026-09-08-plant-based-icon/home-plant-based.png) |

## Two traps for whoever works on this next

**The icon-change notice belongs to SpringBoard, and it blocks the app.**
`XCUIApplication().alerts` does not see it; `XCUIApplication(bundleIdentifier:
"com.apple.springboard").alerts` does. While it is up the app's main thread
is busy, so a UI test that leaves it there will fail its next tap with
"process main thread busy for 30.0s" — which is exactly how accepting the
offer failed in a first capture run. It arrives on its own schedule, so a
test dismisses it when it is there and does not wait for it when it is not;
what proves the switch is the picker's selection, read back from iOS.

**The installed icon outlives the app's container.** `-reset-library-preferences`
cannot put it back — it is not a preference of ours — and neither does
reinstalling from a test run. A simulator left on the plant-based icon makes
the two diet UI tests fail, because a cook already carrying the bowl is not
offered it: `xcrun simctl uninstall <udid> com.ladle.ios` is the reset. The
picker's own UI test therefore reads which icon it started on and puts that
one back.
