# Library Interaction Polish Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the physical Import Inbox tap, make Collections look intentional, and add selective poppy motion and haptics without disturbing the existing review-navigation work.

**Architecture:** Keep the typed `LibraryNavigationState` already present in the working tree. Bound every Home action card to its visible interaction shape, group Collections into one structured panel, and centralize press motion in shared SwiftUI button styles. Drive haptics from existing state transitions with `sensoryFeedback` so feedback occurs only after meaningful changes.

**Tech Stack:** Swift 6, SwiftUI, Observation, XCTest, XCUITest, Xcode 26.5, iOS 26.5 Simulator

---

## Working-tree safety

This plan starts from an intentionally dirty working tree.

Existing app changes that must be preserved:

- `Ladle.xcodeproj/project.pbxproj`
- `Ladle/Library/ImportInboxView.swift`
- `Ladle/Library/LibraryView.swift`
- `Ladle/RecipeDetail/RecipeDetailView.swift`
- `LadleTests/ProjectSmokeTests.swift`
- `LadleTests/LibraryNavigationStateTests.swift`
- `LadleUITests/LibraryFlowTests.swift`

Separately staged asset-catalog changes are user-owned and must not be reset,
unstaged, rewritten, or accidentally included in an interaction commit:

- `Ladle/Resources/Assets.xcassets/OvereasyMark.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeBurger.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeChicken.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeCookies.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeOrzo.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeToast.imageset/Contents.json`
- `Ladle/Resources/Assets.xcassets/RecipeUdon.imageset/Contents.json`

Do not use `git reset`, `git checkout --`, or a plain `git commit` while those
paths are staged. Before every commit, inspect `git diff --cached --name-only`.
Use `git commit --only -- <explicit paths>` so the asset changes remain staged
and outside these commits.

### Task 1: Checkpoint and verify the existing review-navigation fix

**Files:**

- Verify: `Ladle/Library/LibraryView.swift`
- Verify: `Ladle/Library/ImportInboxView.swift`
- Verify: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Verify: `LadleTests/LibraryNavigationStateTests.swift`
- Verify: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Inspect the current state**

Run:

```bash
git status --short
git diff --check
git diff -- \
  Ladle/Library/LibraryView.swift \
  Ladle/Library/ImportInboxView.swift \
  Ladle/RecipeDetail/RecipeDetailView.swift \
  LadleTests/LibraryNavigationStateTests.swift \
  LadleUITests/LibraryFlowTests.swift
```

Expected: the typed navigation path, explicit `reviewDidComplete` callback, and
review UI regressions are present. `git diff --check` has no output.

**Step 2: Run the focused navigation-state tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryNavigationStateTests
```

Expected: all three tests pass.

**Step 3: Run the two review-routing UI tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testReviewedImportLeavesInboxAndInboxCanReopen \
  -only-testing:LadleUITests/LibraryFlowTests/testCompletingLastInboxReviewReturnsHome
```

Expected: both tests pass. This proves the typed route behavior, but does not
yet prove the physical Home-card hit region.

**Step 4: Commit only the navigation work if it is still uncommitted**

First run:

```bash
git diff --cached --name-only
```

Then commit only the prerequisite paths:

```bash
git add LadleTests/LibraryNavigationStateTests.swift
git commit --only -m "fix: cleanly finish import inbox reviews" -- \
  Ladle.xcodeproj/project.pbxproj \
  Ladle/Library/ImportInboxView.swift \
  Ladle/Library/LibraryView.swift \
  Ladle/RecipeDetail/RecipeDetailView.swift \
  LadleTests/ProjectSmokeTests.swift \
  LadleTests/LibraryNavigationStateTests.swift \
  LadleUITests/LibraryFlowTests.swift
```

Expected: only navigation and test paths are committed. The asset-catalog
paths remain staged and unchanged.

### Task 2: Reproduce the physical Import Inbox tap

**Files:**

- Modify: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Add a physical-coordinate regression**

Add this test beside the other Inbox tests:

```swift
func testPhysicalImportInboxCardTapOpensInboxInsteadOfWatch() {
    let app = launchApp()
    app.buttons["Home"].tap()

    let inbox = element(
        in: app,
        identifier: "library.import-inbox"
    )
    XCTAssertTrue(inbox.waitForExistence(timeout: 2))

    let window = app.windows.firstMatch
    let origin = window.coordinate(
        withNormalizedOffset: CGVector(dx: 0, dy: 0)
    )
    origin.withOffset(
        CGVector(dx: inbox.frame.midX, dy: inbox.frame.midY)
    )
    .tap()

    XCTAssertTrue(
        element(in: app, identifier: "library.import-inbox.root")
            .waitForExistence(timeout: 2)
    )
    XCTAssertFalse(
        element(in: app, identifier: "library.watch.root").exists
    )
}
```

This deliberately taps the rendered frame rather than calling `inbox.tap()`.

**Step 2: Run the test to verify RED**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testPhysicalImportInboxCardTapOpensInboxInsteadOfWatch
```

Expected: FAIL because the physical Inbox region opens
`library.watch.root`, matching the real-app reproduction.

If the deterministic fixture does not reproduce, do not weaken the assertion.
Capture `inbox.frame`, `library.watch`'s frame, and a screenshot as test
attachments, then add the smallest one-recipe UI fixture matching the live
Home layout before proceeding.

**Step 3: Commit the RED regression**

```bash
git commit --only -m "test: reproduce physical inbox card tap" -- \
  LadleUITests/LibraryFlowTests.swift
```

Expected: the failing regression is isolated in its own commit and staged
asset changes remain untouched.

### Task 3: Bound Home card interaction regions

**Files:**

- Modify: `Ladle/Library/LibraryHomeView.swift:112-187`
- Test: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Give Inbox and Watch explicit visible shapes**

Add a shared private card shape:

```swift
private var homeCardShape: RoundedRectangle {
    RoundedRectangle(
        cornerRadius: LadleTheme.Corner.card,
        style: .continuous
    )
}
```

On the Import Inbox button:

```swift
.buttonStyle(.plain)
.contentShape(.interaction, homeCardShape)
.clipShape(homeCardShape)
.zIndex(1)
.accessibilityIdentifier("library.import-inbox")
```

On the Watch button, move the background to the button boundary and apply:

```swift
.buttonStyle(.plain)
.contentShape(.interaction, homeCardShape)
.clipShape(homeCardShape)
.accessibilityIdentifier("library.watch")
```

Ensure the button labels use:

```swift
.frame(maxWidth: .infinity, alignment: .leading)
```

Do not use an invisible overlay or a full-height frame to enlarge either card.

**Step 2: Run the physical regression to verify GREEN**

Run the command from Task 2, Step 2.

Expected: the Import Inbox root appears and the Watch root does not.

**Step 3: Run adjacent Home navigation tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testLibraryShowsPendingStatesAndRecipeMetadata \
  -only-testing:LadleUITests/LibraryFlowTests/testWatchWorkspaceExposesCompleteAccessibleControls \
  -only-testing:LadleUITests/LibraryFlowTests/testReviewedImportLeavesInboxAndInboxCanReopen
```

Expected: Inbox, Watch, and review/reopen navigation all pass.

**Step 4: Commit the hit-region fix**

```bash
git commit --only -m "fix: isolate library home card hit regions" -- \
  Ladle/Library/LibraryHomeView.swift \
  LadleUITests/LibraryFlowTests.swift
```

### Task 4: Make Collections an intentional grouped panel

**Files:**

- Modify: `Ladle/Library/LibraryHomeView.swift:247-334`
- Modify: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Add the failing Collections interaction test**

Add:

```swift
func testCollectionRowsAreHittableAndOpenTheirCollection() {
    let app = launchApp()
    app.buttons["Home"].tap()

    let quick = element(
        in: app,
        identifier: "library.collection.quick"
    )
    XCTAssertTrue(quick.waitForExistence(timeout: 2))
    XCTAssertGreaterThanOrEqual(quick.frame.height, 55.5)
    quick.tap()

    XCTAssertTrue(
        element(in: app, identifier: "library.all-recipes")
            .waitForExistence(timeout: 2)
    )
    XCTAssertTrue(app.staticTexts["15-Minute Garlic Butter Udon"].exists)
    XCTAssertFalse(app.staticTexts["Sheet-Pan Gochujang Chicken"].exists)
}
```

**Step 2: Run the test to verify RED**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testCollectionRowsAreHittableAndOpenTheirCollection
```

Expected: FAIL because the collection identifiers and 56-point grouped rows do
not exist.

**Step 3: Build the grouped panel**

Change `collections` to wrap the rows in:

```swift
VStack(spacing: 0) {
    collectionRow(
        "Ready in 30 minutes",
        systemImage: "timer",
        count: viewModel.quickRecipes.count,
        collection: .quick,
        identifier: "quick",
        showsDivider: true
    )
    collectionRow(
        "Favorited",
        systemImage: "heart.fill",
        count: viewModel.favoriteRecipes.count,
        collection: .favorites,
        identifier: "favorites",
        showsDivider: true
    )
    collectionRow(
        "Haven’t cooked yet",
        systemImage: "frying.pan",
        count: viewModel.uncookedRecipes.count,
        collection: .uncooked,
        identifier: "uncooked",
        showsDivider: false
    )
}
.background(
    LadleTheme.oat,
    in: RoundedRectangle(
        cornerRadius: LadleTheme.Corner.card,
        style: .continuous
    )
)
.overlay {
    RoundedRectangle(
        cornerRadius: LadleTheme.Corner.card,
        style: .continuous
    )
    .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
}
.clipShape(
    RoundedRectangle(
        cornerRadius: LadleTheme.Corner.card,
        style: .continuous
    )
)
```

Update `collectionRow` to use:

- a 36-by-36 tinted circular symbol;
- a leading-aligned title;
- the count and chevron in a fixed trailing group;
- `minHeight: 56`;
- 12-point horizontal insets;
- an inset divider beginning after the icon; and
- `library.collection.<identifier>` on the actual button.

Use a full-width rectangular interaction shape inside the clipped grouped
panel.

**Step 4: Run the Collections test to verify GREEN**

Run the command from Step 2.

Expected: PASS.

**Step 5: Verify Dynamic Type behavior**

Add an accessibility-size launch to the same test or
`AccessibilityTests.swift` and assert all three collection buttons remain
hittable and their labels exist.

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/AccessibilityTests \
  -only-testing:LadleUITests/LibraryFlowTests/testCollectionRowsAreHittableAndOpenTheirCollection
```

Expected: focused accessibility and Collections tests pass.

**Step 6: Commit**

```bash
git commit --only -m "feat: polish library collections panel" -- \
  Ladle/Library/LibraryHomeView.swift \
  LadleUITests/LibraryFlowTests.swift \
  LadleUITests/AccessibilityTests.swift
```

### Task 5: Add the shared poppy press language

**Files:**

- Modify: `Ladle/Design/LadleComponents.swift:1-40`
- Modify: `Ladle/Library/LibraryHomeView.swift`
- Modify: `Ladle/Library/LibraryChrome.swift`
- Modify: `Ladle/Library/AllRecipesView.swift`
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Modify: `Ladle/Cooking/FocusModeView.swift`
- Modify: `Ladle/Cooking/FullRecipeView.swift`

**Step 1: Add a shared press style**

Add:

```swift
enum LadlePressKind {
    case card
    case control

    var scale: CGFloat {
        switch self {
        case .card: 0.97
        case .control: 0.94
        }
    }

    var duration: TimeInterval {
        switch self {
        case .card: 0.18
        case .control: 0.15
        }
    }
}

struct LadlePressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var kind: LadlePressKind = .control

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                reduceMotion || !isEnabled
                    ? 1
                    : (configuration.isPressed ? kind.scale : 1)
            )
            .opacity(
                !isEnabled
                    ? 0.48
                    : (configuration.isPressed ? 0.86 : 1)
            )
            .animation(
                reduceMotion
                    ? nil
                    : .snappy(
                        duration: kind.duration,
                        extraBounce: 0
                    ),
                value: configuration.isPressed
            )
    }
}
```

Update `LadlePrimaryButtonStyle` to use `0.97` and a 180 ms snappy,
zero-bounce animation. Under Reduce Motion it must keep scale at `1`.

**Step 2: Apply the style deliberately**

Use `.buttonStyle(LadlePressButtonStyle(kind: .card))` for:

- Import Inbox;
- Watch;
- collection rows; and
- Home recipe thumbnails.

Use `.buttonStyle(LadlePressButtonStyle())` for:

- Library top-bar circular buttons;
- collapsible section headers;
- favorite buttons;
- cooking step navigation; and
- timer/reset controls that currently use `.plain`.

Do not apply the style to system back buttons, segmented pickers, or swipe
actions.

**Step 3: Add screen-level state transitions**

For Collections and Saved This Week, replace `.default` with:

```swift
withAnimation(
    reduceMotion
        ? nil
        : .snappy(duration: 0.22, extraBounce: 0)
) {
    toggle()
}
```

Give expanded content:

```swift
.transition(
    reduceMotion
        ? .opacity
        : .opacity.combined(with: .move(edge: .top))
)
```

Keep grid/list reflow at 250 ms or less with `extraBounce: 0`.

**Step 4: Run interaction regressions**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests \
  -only-testing:LadleUITests/CookingModeTests \
  -only-testing:LadleUITests/RecipeDetailTests
```

Expected: all focused UI tests pass and every modified control remains
hittable.

**Step 5: Commit**

```bash
git commit --only -m "feat: add tactile press motion" -- \
  Ladle/Design/LadleComponents.swift \
  Ladle/Library/LibraryHomeView.swift \
  Ladle/Library/LibraryChrome.swift \
  Ladle/Library/AllRecipesView.swift \
  Ladle/RecipeDetail/RecipeDetailView.swift \
  Ladle/Cooking/FocusModeView.swift \
  Ladle/Cooking/FullRecipeView.swift
```

### Task 6: Add selective haptic feedback

**Files:**

- Modify: `Ladle/Library/LibraryView.swift`
- Modify: `Ladle/Library/AllRecipesView.swift`
- Modify: `Ladle/Library/RecipeGridCard.swift`
- Modify: `Ladle/Library/RecipeListRow.swift`
- Modify: `Ladle/Library/WatchView.swift`
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Modify: `Ladle/Cooking/FocusModeView.swift`
- Modify: `Ladle/Cooking/FullRecipeView.swift`
- Modify: `Ladle/Cooking/RecipeTimer.swift`

**Step 1: Add navigation and selection feedback**

Attach feedback to stable state transitions, not raw tap gestures.

In `LibraryView`:

```swift
.sensoryFeedback(.selection, trigger: section)
.sensoryFeedback(
    .impact(weight: .light, intensity: 0.65),
    trigger: navigation.path.count
) { oldCount, newCount in
    newCount > oldCount
}
```

This produces an impact only for pushes, not back navigation.

In `AllRecipesView`, attach `.selection` to `viewModel.displayMode`. Attach
selection feedback to favorite-state changes in grid, list, Watch, and Recipe
Detail.

**Step 2: Add completion feedback**

In `RecipeDetailView`:

```swift
.sensoryFeedback(.success, trigger: reviewIsPending) {
    wasPending,
    isPending in
    wasPending && !isPending
}
```

Add success feedback when an ingredient or cooking step becomes complete. Add
medium impact when a timer changes to `.running`, selection feedback when it
changes to `.paused`, and success feedback when it becomes `.finished`.

Use the existing operation-error state for warning/error feedback. Do not emit
success feedback until the persistence operation has actually succeeded.

**Step 3: Keep the haptic map restrained**

Verify there is no haptic for:

- scrolling;
- ordinary back navigation;
- passive load completion;
- section collapse caused by restored preferences; or
- repeated timer ticks.

**Step 4: Run focused behavior tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryViewModelTests \
  -only-testing:LadleTests/CookingViewModelTests \
  -only-testing:LadleUITests/LibraryFlowTests \
  -only-testing:LadleUITests/CookingModeTests \
  -only-testing:LadleUITests/RecipeDetailTests
```

Expected: all focused state and UI tests pass. Haptic quality itself requires a
real-device follow-up, but simulator state transitions must remain correct.

**Step 5: Commit**

```bash
git commit --only -m "feat: add meaningful interaction haptics" -- \
  Ladle/Library/LibraryView.swift \
  Ladle/Library/AllRecipesView.swift \
  Ladle/Library/RecipeGridCard.swift \
  Ladle/Library/RecipeListRow.swift \
  Ladle/Library/WatchView.swift \
  Ladle/RecipeDetail/RecipeDetailView.swift \
  Ladle/Cooking/FocusModeView.swift \
  Ladle/Cooking/FullRecipeView.swift \
  Ladle/Cooking/RecipeTimer.swift
```

### Task 7: Make review completion visually clean

**Files:**

- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Modify: `Ladle/Library/ImportInboxView.swift`
- Modify: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Strengthen the existing review regression**

Extend `testReviewedImportLeavesInboxAndInboxCanReopen` to assert:

- the reviewed import identifier disappears;
- the Import Inbox root remains when other jobs exist;
- the reviewed recipe no longer exposes `recipe.complete-review`; and
- a second physical Home-card tap still reopens the inbox.

Keep `testCompletingLastInboxReviewReturnsHome` as the empty-inbox case.

**Step 2: Run the tests before visual changes**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testReviewedImportLeavesInboxAndInboxCanReopen \
  -only-testing:LadleUITests/LibraryFlowTests/testCompletingLastInboxReviewReturnsHome
```

Expected: the route assertions pass from the existing typed-navigation work.

**Step 3: Add a short success state**

On successful **Mark reviewed**:

1. change the control to a checkmark and “Reviewed”;
2. trigger success feedback;
3. apply the reviewed recipe;
4. allow no more than 180 ms for the visible state change; and
5. invoke `reviewDidComplete`.

Cancel the pending transition if Recipe Detail disappears. Do not delay or
navigate on persistence failure.

Under Reduce Motion, skip the scale/move portion and navigate immediately
after the success state is applied.

When returning to Import Inbox, animate the updated list with:

```swift
.animation(
    reduceMotion
        ? nil
        : .snappy(duration: 0.2, extraBounce: 0),
    value: viewModel.actionableImportJobs.map(\.id)
)
```

**Step 4: Re-run the two review regressions**

Run the command from Step 2.

Expected: both tests pass with no stale reviewed row and correct routing.

**Step 5: Commit**

```bash
git commit --only -m "feat: polish review completion feedback" -- \
  Ladle/RecipeDetail/RecipeDetailView.swift \
  Ladle/Library/ImportInboxView.swift \
  LadleUITests/LibraryFlowTests.swift
```

### Task 8: Verify, build, and launch on the dedicated simulator

**Files:**

- Verify: all modified Swift and test files
- Create: `docs/verification/2026-07-27-library-interaction-polish.md`

**Step 1: Check the diff and staged-path safety**

Run:

```bash
git diff --check
git status --short
git diff --cached --name-only
```

Expected: no whitespace errors. The asset changes are still intact and have
not been folded into interaction commits.

**Step 2: Run the focused suite**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryNavigationStateTests \
  -only-testing:LadleTests/LibraryViewModelTests \
  -only-testing:LadleTests/CookingViewModelTests \
  -only-testing:LadleUITests/LibraryFlowTests \
  -only-testing:LadleUITests/RecipeDetailTests \
  -only-testing:LadleUITests/CookingModeTests
```

Expected: all focused tests pass.

**Step 3: Run the domain package**

Run:

```bash
swift test --package-path Packages/LadleCore
```

Expected: all package tests pass.

**Step 4: Build the simulator app**

Run:

```bash
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7'
```

Expected: `** BUILD SUCCEEDED **`.

**Step 5: Check the local backend**

Run:

```bash
curl --fail http://api.ladle.localhost/health/live
curl --fail http://api.ladle.localhost/health/ready
```

Expected: live and ready responses.

**Step 6: Launch from Xcode**

Use Xcode's Run action with:

- Scheme: `Ladle`
- Device: `Overeasy - iPhone 16 Pro`
- UDID: `5CDD8E03-C52C-449A-8332-28F29FF937B7`

Do not replace this with a command-line `simctl install`: the prior
command-line installation had empty code-sign entitlements and caused the
misleading “couldn't connect to internet” error.

**Step 7: Manually verify**

On the dedicated simulator:

1. Tap the center, icon side, and chevron side of Import Inbox; every tap opens
   Import Inbox.
2. Return Home and tap Watch; it opens Watch and never captures Inbox taps.
3. Review an import; the action shows success and the reviewed row is gone.
4. With remaining jobs, return to Import Inbox.
5. With no remaining jobs, return to Home.
6. Reopen Import Inbox after returning Home.
7. Inspect Collections in light, dark, and accessibility Dynamic Type.
8. Check press motion on major cards, primary buttons, collection rows, and
   cooking controls.
9. Enable Reduce Motion and confirm there is no scaling or moving transition.
10. Verify favorite, review, cooking-step, and timer feedback on a physical
    device when available.

**Step 8: Record verification**

Document commands, results, any unrelated pre-existing failures, simulator
screenshots, and the Xcode launch confirmation in:

```text
docs/verification/2026-07-27-library-interaction-polish.md
```

Commit only the verification note:

```bash
git add docs/verification/2026-07-27-library-interaction-polish.md
git commit --only -m "docs: verify library interaction polish" -- \
  docs/verification/2026-07-27-library-interaction-polish.md
```
