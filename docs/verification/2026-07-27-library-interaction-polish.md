# Library Interaction Polish Verification

## Purpose

Verify the Library hit-region repair, grouped Collections panel, zero-bounce
press language, selective haptics, and reviewed-import routing on the dedicated
Overeasy simulator without restoring the removed UI-test target.

## User-visible behavior

- The complete visible Import Inbox card now owns its rounded hit region.
  Center, icon-side, and chevron-side taps open Import Inbox rather than Watch.
- Watch retains its own rounded hit region and continues to open Watch.
- Collections use one grouped oat panel with aligned icons, counts, chevrons,
  and inset dividers.
- Major cards and controls use one zero-bounce press language. Reduce Motion
  keeps custom press scale at `1` and removes moving custom section
  transitions.
- Favorites, review completion, cooking completion, timers, navigation, and
  real failures use feedback only for meaningful state changes.
- Review completion persists before showing a brief `Reviewed` success state.
  Typed navigation returns to Import Inbox when work remains and Home when the
  inbox is empty.

## Important decisions

- The user directed removal of the complete `LadleUITests` suite. Physical
  hit regions and appearance are therefore verified manually through Xcode,
  while state and persistence behavior remain covered by `LadleTests`.
- Xcode Run is the launch path. No command-line simulator install was used,
  avoiding the entitlement-stripping failure reproduced earlier.
- Haptic policy and state triggers are simulator- and unit-test verified.
  Tactile quality still requires a physical-device pass.
- The simulator's single stored inbox row did not expose an actionable review
  flow during coordinate interaction. It was not deleted or rewritten to
  manufacture a manual review result. Both review-routing branches are covered
  by fresh typed tests.

## Affected components

- `Ladle/Library/LibraryHomeView.swift`
- `Ladle/Library/LibraryView.swift`
- `Ladle/Library/LibraryViewModel.swift`
- `Ladle/Library/ImportInboxView.swift`
- `Ladle/Design/LadleComponents.swift`
- `Ladle/RecipeDetail/RecipeDetailView.swift`
- Library recipe cards, Watch, cooking controls, and recipe timers
- `LadleTests/DesignTokenTests.swift`
- `LadleTests/LibraryNavigationStateTests.swift`
- `LadleTests/LibraryViewModelTests.swift`
- Xcode project, schemes, XcodeGen definition, and README UI-test references

## Automated verification

All commands ran from the worktree on branch
`codex/library-interaction-polish`.

### Project shape

```text
xcodebuild -list -project Ladle.xcodeproj
```

Result:

- Targets: `Ladle`, `LadleShare`, `LadleTests`
- Schemes: `Ladle`, `LadleCore`
- No `LadleUITests` target, product, source suite, or shared scheme remains.

### App unit tests

```text
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination \
  'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests
```

Result: `** TEST SUCCEEDED **`; 159 tests executed, 158 passed, 1 intentional
live-device test skipped, 0 failures.

Result bundle:

```text
/Users/chetangoel/Library/Developer/Xcode/DerivedData/Ladle-bvgjbseiioivmygpvpgbfeletsdy/Logs/Test/Test-Ladle-2026.07.27_18-29-29--0400.xcresult
```

### Domain package

```text
swift test --package-path Packages/LadleCore
```

Result: 42 tests in 9 suites passed.

### App and Share Extension builds

```text
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -configuration Debug \
  -destination \
  'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7'
```

Result: `** BUILD SUCCEEDED **`. The build compiled and embedded
`LadleShare.appex`, then validated the embedded binary.

The standalone extension checkpoint used the scheme-equivalent simulator
architecture and DerivedData roots:

```text
xcodebuild build \
  -project Ladle.xcodeproj \
  -target LadleShare \
  -configuration Debug \
  -sdk iphonesimulator \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  SYMROOT=/Users/chetangoel/Library/Developer/Xcode/DerivedData/Ladle-bvgjbseiioivmygpvpgbfeletsdy/Build/Products \
  OBJROOT=/Users/chetangoel/Library/Developer/Xcode/DerivedData/Ladle-bvgjbseiioivmygpvpgbfeletsdy/Build/Intermediates.noindex
```

Result: `** BUILD SUCCEEDED **`.

A diagnostic target-only command without those settings failed after Xcode
ignored its destination and selected both simulator architectures. Matching
the successful scheme's `arm64` architecture and DerivedData roots confirmed
that this was an invocation problem, not a Share Extension source defect.
The diagnostic workspace-local build products were moved out of the worktree.

### Backend

```text
curl --fail --show-error http://api.ladle.localhost/health/live
curl --fail --show-error http://api.ladle.localhost/health/ready
```

Results:

- `{"status":"live"}`
- `{"status":"ready", ...}` with broker, worker, database, storage, and Redis
  checks ready.

## Xcode launch

Xcode opened the project from:

```text
/Users/chetangoel/.codex/worktrees/f3cb/recipe-app/Ladle.xcodeproj
```

Run configuration:

- Scheme: `Ladle`
- Destination: `Overeasy - iPhone 16 Pro`
- UDID: `5CDD8E03-C52C-449A-8332-28F29FF937B7`
- Xcode activity result: `Running Ladle on Overeasy - iPhone 16 Pro`

No `simctl install` command was used.

## Manual simulator verification

- PASS: center tap on Import Inbox opened Import Inbox.
- PASS: icon-side tap on Import Inbox opened Import Inbox.
- PASS: chevron-side tap on Import Inbox opened Import Inbox.
- PASS: each return to Home allowed Import Inbox to reopen.
- PASS: the Watch card opened Watch and did not capture Inbox taps.
- PASS: the grouped Collections panel rendered in standard light appearance.
- PASS: Xcode dark-appearance and XXX Large Dynamic Type overrides preserved
  row grouping, horizontal alignment, and readable titles/counts.
- PASS: the Reduce Motion runtime override was active and navigation remained
  functional. Unit tests verify custom press scale `1`, zero review delay, and
  zero-bounce timing; native `NavigationStack` transitions remain
  system-controlled.
- PASS: favorite state changed only after persistence and was restored to its
  original state after inspection.
- COVERED BY TEST: review completion with remaining work returns to Import
  Inbox.
- COVERED BY TEST: completing the last review returns to Home and Import Inbox
  can reopen.
- PHYSICAL DEVICE FOLLOW-UP: confirm tactile quality for favorite, review,
  cooking completion, timer start/resume/pause/finish, and errors.

## Screenshots

- [Library Home, light](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/01-library-home-light.png)
- [Import Inbox after center tap](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/02-import-inbox-center-tap.png)
- [Watch routing](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/03-watch-routing.png)
- [Collections, light](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/04-collections-light.png)
- [Collections, dark and XXX Large](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/05-collections-dark-accessibility-type.png)
- [Reduce Motion navigation check](/Users/chetangoel/.codex/visualizations/2026/07/27/019fa595-a700-7110-8dc9-444ae6dcb19c/library-interaction-polish/06-reduce-motion-navigation.png)

## Safety

The seven user-owned asset-catalog diffs retained their original aggregate
hash throughout implementation:

```text
274f6b096c2d0c0693f91159da15dfe8a6e04ee88623130b3a9d954c4ab9bce3
```

They were never staged, rewritten, or included in an interaction commit. The
pre-existing untracked workspace settings file was also left untouched.
