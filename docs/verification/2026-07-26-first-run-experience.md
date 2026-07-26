# First-Run Experience Refinement

## Purpose

Move a new user from launch to the first useful recipe action with less
ceremony, while covering the empty, loading, recovery, and accessibility
details around that path.

The activation goal is the first structured recipe created from a saved link.
The audience is a mixed-experience home cook using the app one-handed.

## User-visible behavior

- The system launch surface now uses the Paper asset, avoiding a white flash
  before the app's warm browsing surface appears.
- First launch presents one welcome surface instead of a four-page passive
  tour. It states the link-to-recipe promise, the two ways to save, and the
  cooking benefit without delaying entry.
- Continue with Apple handles both account creation and returning sign-in.
  Guest entry is a full-size secondary action with the ten-recipe limit and
  lossless later sign-in stated before entry.
- Authentication shows disabled controls, visible progress, and concise
  recovery copy when the backend or Apple flow cannot complete.
- A genuinely empty Home view now explains what will appear, opens the real
  Add Recipe sheet, and teaches Share Extension use at the point it matters.
- Empty All Recipes removes irrelevant sort and filter controls, then offers
  the same first-recipe action.
- The obscured library is hidden from the accessibility tree while the welcome
  surface is active. Welcome content scrolls independently at large Dynamic
  Type sizes while account actions remain reachable.
- Disabled primary and secondary buttons now expose a consistent muted visual
  state throughout the app.

## Decisions

- Preserve the existing bottom-sheet presentation over a softened library so
  first launch still feels native to the established product.
- Replace feature education with activation. Advanced behavior remains
  discoverable in the actual library, import, and cooking surfaces.
- Use SF Symbols and existing Ladle tokens instead of adding promotional
  imagery. The frying-pan and link mark communicates the transformation while
  food photography remains reserved for recipes.
- Keep Apple and guest as the only honest entry paths because Apple is the
  current account provider and remote imports require a session.
- Show the first-use state only when both recipes and import jobs are empty.
  Active or recoverable imports continue to use the existing inbox behavior.

## Affected components

- `Config/Ladle-Info.plist`
- `Ladle/Account/WelcomeView.swift`
- `Ladle/App/LadleApp.swift`
- `Ladle/App/RootView.swift`
- `Ladle/Design/LadleComponents.swift`
- `Ladle/Library/LibraryView.swift`
- `Ladle/Library/LibraryHomeView.swift`
- `Ladle/Library/AllRecipesView.swift`
- `LadleTests/ProjectSmokeTests.swift`
- `LadleUITests/LadleLaunchTests.swift`
- `LadleUITests/AccessibilityTests.swift`
- `DESIGN.md`
- `README.md`

## Verification

- UI coverage was written first and observed failing against the passive tour,
  seeded empty launch, generic All Recipes state, and exposed background
  controls.
- Focused red-green coverage verifies the concise welcome, guest handoff,
  empty Home and All Recipes actions, and the real Add Recipe presentation.
- iPhone 17 Pro screenshots were reviewed at the default content size and
  Accessibility Large for the welcome and empty Home state.
- Accessibility Large coverage verifies that Apple and guest actions remain
  visible, inside the viewport, and at least 44 points tall.
- The `-empty-library` launch argument keeps UI testing deterministic without
  changing production persistence behavior.
- The focused app run passed five smoke tests and five UI tests: four launch
  flows plus the Accessibility Large welcome check.
- `LadleCore` passed all 37 tests across eight suites.
- The generic iOS Simulator milestone build compiled both Ladle and
  LadleShare, and `git diff --check` passed.
