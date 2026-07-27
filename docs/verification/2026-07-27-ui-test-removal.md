# UI Test Removal

## Purpose

Remove the Xcode UI-test suite while preserving app, Share Extension, unit,
and package coverage.

## User-visible behavior

The app is unchanged. Xcode no longer exposes or builds a `LadleUITests`
target or the UI-test-only `LadleLiveBackend` scheme.

## Decisions

- Removed all eight files under `LadleUITests`.
- Removed the UI-test target, product, dependency, build settings, and source
  phase from the Xcode project and XcodeGen definition.
- Removed UI-test entries from the shared `Ladle` scheme.
- Removed the UI-test-only live-backend scheme and launch fixture.
- Retained `LadleTests` and `Packages/LadleCore` tests.

## Affected components

- `Ladle.xcodeproj`
- `project.yml`
- `README.md`
- `LadleUITests`

## Verification

- `xcodebuild -list -project Ladle.xcodeproj` lists only `Ladle`,
  `LadleShare`, and `LadleTests`.
- The shared project and scheme contain no `LadleUITests` references.
- `xcodebuild test -project Ladle.xcodeproj -scheme Ladle -destination
  'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7'
  -only-testing:LadleTests` passed 153 tests with 1 intentional live-device
  skip and 0 failures.
