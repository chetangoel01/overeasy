# Account Sheet Polish

## Purpose

Improve the Account sheet's hierarchy and scanability without changing its
presentation, account data, transparency copy, initializer, or sign-out
behavior.

## User-visible behavior

- Account state, recipe count, and the shortened installation ID appear in one
  grouped summary instead of three competing surfaces.
- The existing storage and privacy statements appear as individually readable
  rows with quiet dividers and paprika markers.
- The existing device-removal explanation now precedes the sign-out button so
  the consequence is clear before the action.
- Sign out still uses the same secondary button, loading state, confirmation
  dialog, async action, dismissal, and `account.sign-out` accessibility
  identifier.

## Decisions

- Transparency content moved to a dedicated "Privacy & data" screen behind a
  single navigation row, keeping the Account sheet to identity, one privacy row, and
  sign-out. (Follow-up to the inline first pass, per product direction.)
- Reuse `LadleSectionHeader`, `ladleFont`, `LadlePrimaryButtonStyle`, the Ladle
  palette, spacing scale, and `LadleTheme.Corner.control`.
- Use one field-colored summary with open transparency lists, avoiding a stack
  of identical cards.
- Stack account labels and values at accessibility Dynamic Type sizes while
  preserving the compact horizontal presentation at standard sizes.

## Affected components

- `Ladle/Account/AccountSheet.swift`
- `LadleUITests/LadleLaunchTests.swift`
- `LadleUITests/AccessibilityTests.swift`

## Verification

- Red-green UI coverage confirms the transparency statements are separate
  accessibility elements and the sign-out confirmation retains its title and
  message.
- Focused Account UI tests pass on iPhone 17 Pro at standard and Accessibility
  Large content sizes.
- Retained screenshots were reviewed for the account summary, both
  transparency sections, the fully visible sign-out action, and the native
  confirmation dialog.
- `git diff --check` passes.
- The standalone requested build was attempted after the successful simulator
  tests, but the sandbox lost its CoreSimulator connection and denied SwiftPM
  user-cache writes before compilation. The same Ladle and Share Extension
  targets compiled successfully as part of the immediately preceding focused
  iPhone 17 Pro test runs.
