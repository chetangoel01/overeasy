# Ladle Native iOS Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build the complete Ladle v1 native iPhone vertical slice, matching the supplied screens while providing real local persistence, a Share Extension, safe import state handling, cooking modes, and explicit HealthKit export.

**Architecture:** A generated Xcode workspace contains the Ladle SwiftUI app, Ladle Share Extension, app unit tests, and UI tests. A local `LadleCore` Swift package holds Foundation-only domain models and rules shared by both targets; SwiftData and platform services remain in the app layer behind protocols. Deterministic demo services make every flow work locally while preserving production backend boundaries.

**Tech Stack:** Swift 6.3, SwiftUI, Observation, SwiftData, HealthKit, UserNotifications, App Groups, XCTest, XCUITest, XcodeGen, iOS 26.5.

---

## Working conventions

- Run domain tests with:

  ```bash
  swift test --package-path Packages/LadleCore
  ```

- Run app unit tests with:

  ```bash
  xcodebuild test -project Ladle.xcodeproj -scheme Ladle -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LadleTests
  ```

- Run UI tests with:

  ```bash
  xcodebuild test -project Ladle.xcodeproj -scheme Ladle -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LadleUITests
  ```

- Use `CODE_SIGNING_ALLOWED=NO` for build-only verification. Use normal simulator signing for tests.
- Keep commits task-sized. Run `git diff --check` before every commit.
- Every behavior begins with a failing test and follows red-green-refactor.

### Task 1: Create the project and test harness

**Files:**

- Create: `project.yml`
- Create: `Config/Ladle-Info.plist`
- Create: `Config/LadleShare-Info.plist`
- Create: `Config/Ladle.entitlements`
- Create: `Config/LadleShare.entitlements`
- Create: `Ladle/App/LadleApp.swift`
- Create: `Ladle/App/RootView.swift`
- Create: `Ladle/Resources/Assets.xcassets/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/AccentColor.colorset/Contents.json`
- Create: `LadleTests/ProjectSmokeTests.swift`
- Create: `LadleUITests/LadleLaunchTests.swift`

**Step 1: Add the XcodeGen specification and minimal harness**

Define:

- app target `Ladle`, bundle identifier `com.ladle.ios`;
- extension target `LadleShare`, bundle identifier `com.ladle.ios.share`;
- unit test target `LadleTests`;
- UI test target `LadleUITests`;
- local package dependency at `Packages/LadleCore`;
- iOS deployment target `26.5`;
- Swift language version `6.0`;
- application and extension App Group `group.com.ladle.ios`;
- HealthKit capability for the application;
- extension embedding in the application.

The minimal root renders a neutral `"Test harness"` label. This is scaffolding, not product behavior.

**Step 2: Generate the project**

Run:

```bash
xcodegen generate
```

Expected: `Ladle.xcodeproj` is created with app, extension, unit test, and UI test targets.

**Step 3: Write the failing launch test**

```swift
@MainActor
final class LadleLaunchTests: XCTestCase {
    func testLaunchShowsRecipeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-onboarding-complete"]
        app.launch()

        XCTAssertTrue(app.otherElements["library.root"].waitForExistence(timeout: 2))
    }
}
```

**Step 4: Run the test to verify it fails**

Run the UI-test command above.

Expected: FAIL because `library.root` does not exist.

**Step 5: Add the minimal library root**

Replace the harness label with a `NavigationStack` whose root container has accessibility identifier `library.root`.

**Step 6: Run build and launch test**

Run:

```bash
xcodebuild build -project Ladle.xcodeproj -scheme Ladle -destination 'platform=iOS Simulator,name=iPhone 17' CODE_SIGNING_ALLOWED=NO
xcodebuild test -project Ladle.xcodeproj -scheme Ladle -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:LadleUITests/LadleLaunchTests/testLaunchShowsRecipeLibrary
```

Expected: BUILD SUCCEEDED and 1 UI test passes.

**Step 7: Commit**

```bash
git add project.yml Config Ladle LadleTests LadleUITests Ladle.xcodeproj
git commit -m "chore: scaffold Ladle iOS project"
```

### Task 2: Add shared recipe and import domain models

**Files:**

- Create: `Packages/LadleCore/Package.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/Recipe.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/ImportJob.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/RecipeSource.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/Nutrition.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/Uncertainty.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/ImportJobTests.swift`

**Step 1: Write failing import transition tests**

Cover:

```swift
@Test func parsingCanBecomeReady()
@Test func parsingCanBecomeNeedsReview()
@Test func parsingCanFail()
@Test func readyCannotReturnToParsing()
@Test func failedReimportRetainsCurrentRecipe()
```

The key safety assertion is:

```swift
var job = ImportJob.reimporting(
    sourceURL: sampleURL,
    currentRecipeID: usableRecipeID
)
job = try job.transitioning(to: .failed(.parserUnavailable))

#expect(job.currentRecipeID == usableRecipeID)
#expect(job.candidateRecipeID == nil)
```

**Step 2: Run tests to verify they fail**

Run the domain-test command.

Expected: compile failure because the domain types do not exist.

**Step 3: Implement minimal value types and transition rules**

Use `struct` value types conforming to `Codable`, `Hashable`, `Identifiable`, and `Sendable`. Model exactly four visible states and reject transitions with `ImportTransitionError`.

**Step 4: Run domain tests**

Expected: all import tests pass.

**Step 5: Refactor common identifiers and timestamps**

Add typed aliases only where they reduce ambiguity. Keep stored timestamps injectable for deterministic tests.

**Step 6: Run tests and commit**

```bash
git add Packages/LadleCore
git commit -m "feat: add recipe and import domain models"
```

### Task 3: Implement guest, filtering, nutrition, and cooking rules

**Files:**

- Create: `Packages/LadleCore/Sources/LadleCore/GuestPolicy.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/RecipeQuery.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/CookingSession.swift`
- Modify: `Packages/LadleCore/Sources/LadleCore/Nutrition.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/GuestPolicyTests.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/RecipeQueryTests.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/NutritionTests.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/CookingSessionTests.swift`

**Step 1: Write failing guest-policy tests**

Assert:

- counts 0 through 8 allow silent saving;
- count 9 returns `allowWithAccountPrompt`;
- count 10 returns `limitReached`;
- reaching the limit never changes access to existing recipe identifiers.

**Step 2: Run the guest tests and verify RED**

Expected: missing `GuestPolicy`.

**Step 3: Implement the minimal guest policy and verify GREEN**

Use a pure function:

```swift
public static func decision(savedRecipeCount: Int) -> GuestSaveDecision
```

**Step 4: Write failing query tests**

Cover case-insensitive title and creator search, favorites, maximum time, maximum calories, recent/time/calorie/alphabetical sorting, and stable tie-breaking.

**Step 5: Implement `RecipeQuery` and verify GREEN**

Keep querying pure and deterministic.

**Step 6: Write failing nutrition scaling tests**

Assert that 1.5 consumed servings scales every available nutrient from a one-serving basis and preserves absent values as absent.

**Step 7: Implement nutrition scaling and verify GREEN**

Use `Decimal` for stored nutrient values.

**Step 8: Write failing cooking-session tests**

Cover step bounds, previous/next behavior, completed ingredients and steps, mode switching, and position preservation.

**Step 9: Implement cooking session behavior and verify GREEN**

**Step 10: Run the full package suite and commit**

```bash
git add Packages/LadleCore
git commit -m "feat: add Ladle domain policies"
```

### Task 4: Add SwiftData persistence and deterministic fixtures

**Files:**

- Create: `Ladle/Data/StoredRecipe.swift`
- Create: `Ladle/Data/StoredImportJob.swift`
- Create: `Ladle/Data/RecipeRepository.swift`
- Create: `Ladle/Data/SwiftDataRecipeRepository.swift`
- Create: `Ladle/Data/PreviewFixtures.swift`
- Create: `Ladle/App/AppEnvironment.swift`
- Create: `LadleTests/SwiftDataRecipeRepositoryTests.swift`

**Step 1: Write failing repository tests**

Use an in-memory `ModelContainer` and verify:

- saving and fetching a recipe round-trips ordered ingredients and steps;
- an update preserves its stable identifier;
- deleting a recipe does not delete an unrelated import;
- a failed re-import update keeps the current stored recipe;
- fixture seeding is idempotent.

**Step 2: Run app unit tests and verify RED**

Expected: repository symbols are missing.

**Step 3: Implement SwiftData storage models and mappers**

Persist nested domain values using Codable-backed transformable data where relational querying is unnecessary. Store searchable/sortable fields directly on `StoredRecipe`.

**Step 4: Implement the repository and fixture seeding**

Seed the recipes and import states shown in the supplied screens only when the store is empty or `-demo-data` is passed.

**Step 5: Run repository tests and verify GREEN**

**Step 6: Run all domain and app unit tests**

Expected: all tests pass.

**Step 7: Commit**

```bash
git add Ladle/App Ladle/Data LadleTests
git commit -m "feat: persist recipes with SwiftData"
```

### Task 5: Build the design system and generated food assets

**Files:**

- Create: `Ladle/Design/LadleTheme.swift`
- Create: `Ladle/Design/LadleTypography.swift`
- Create: `Ladle/Design/LadleComponents.swift`
- Create: `Ladle/Resources/Assets.xcassets/Paper.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Field.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Ink.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Paprika.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Review.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Success.colorset/Contents.json`
- Create: `Ladle/Resources/Assets.xcassets/Recipe*/Contents.json`
- Create: `LadleTests/DesignTokenTests.swift`

**Step 1: Write failing token tests**

Verify the approved hex values:

- paper `#FBFAF7`;
- field `#F1EEE8`;
- ink `#1F1D1A`;
- paprika `#B44B24`;
- review tint `#F6ECD9`;
- success `#3D7A44`.

Also verify compact, regular, and cooking corner/spacing constants remain internally consistent.

**Step 2: Run the test and verify RED**

Expected: `LadleTheme` is missing.

**Step 3: Implement theme, typography, and core components**

Create reusable primary buttons, pills, section headers, metadata labels, estimate labels, cards, and sheet handles. Use Dynamic Type-aware system fonts and `.serif` for editorial headings.

**Step 4: Generate six original food photographs**

Create burger, lemon-orzo, garlic-udon, gochujang-chicken, ricotta-toast, and miso-cookie assets with consistent editorial lighting and crops. Add them to the asset catalog at 1x simulator resolution with correct `Contents.json`.

**Step 5: Run token tests and asset-catalog build**

Expected: token tests pass and `actool` reports no missing assets.

**Step 6: Commit**

```bash
git add Ladle/Design Ladle/Resources LadleTests
git commit -m "feat: add Ladle editorial design system"
```

### Task 6: Implement onboarding and account-state behavior

**Files:**

- Create: `Ladle/Account/AccountSession.swift`
- Create: `Ladle/Account/WelcomeView.swift`
- Create: `Ladle/Account/GuestLimitView.swift`
- Create: `LadleTests/AccountSessionTests.swift`
- Modify: `Ladle/App/RootView.swift`
- Modify: `LadleUITests/LadleLaunchTests.swift`

**Step 1: Write failing account-session tests**

Verify onboarding is presented for a new guest, guest continuation records completion, and the account prompt is returned before the tenth save.

**Step 2: Verify RED, implement the session, and verify GREEN**

Back onboarding state with an injected key-value store so tests do not mutate standard defaults.

**Step 3: Write the failing onboarding UI test**

Assert the welcome heading, all three account actions, and guest-limit explanation exist. Tap Continue as Guest and assert `library.root`.

**Step 4: Run UI test and verify RED**

**Step 5: Implement the edited welcome sheet and guest-limit sheet**

Match screen 1a and 1i. Sign in and account creation may open honest development placeholders, but guest continuation is fully functional.

**Step 6: Run UI test and accessibility audit**

**Step 7: Commit**

```bash
git add Ladle/Account Ladle/App LadleTests LadleUITests
git commit -m "feat: add Ladle welcome and guest flow"
```

### Task 7: Implement the recipe library, search, filters, and display modes

**Files:**

- Create: `Ladle/Library/LibraryViewModel.swift`
- Create: `Ladle/Library/LibraryView.swift`
- Create: `Ladle/Library/RecipeGridCard.swift`
- Create: `Ladle/Library/RecipeListRow.swift`
- Create: `Ladle/Library/PendingImportCard.swift`
- Create: `Ladle/Library/FilterSheet.swift`
- Create: `LadleTests/LibraryViewModelTests.swift`
- Create: `LadleUITests/LibraryFlowTests.swift`
- Modify: `Ladle/App/RootView.swift`

**Step 1: Write failing view-model tests**

Verify loading, search, sorting, filter composition, pending-state grouping, grid/list persistence, and favorite changes.

**Step 2: Verify RED, implement the view model, and verify GREEN**

The view model depends only on `RecipeRepository` and domain `RecipeQuery`.

**Step 3: Write failing library UI tests**

Assert:

- pending cards expose parsing, needs-review, and failed labels;
- saved cards expose title, time, estimated calories, and favorite state;
- searching “orzo” leaves only the orzo recipe;
- switching to list mode preserves search;
- applying maximum time shows a removable active-filter pill.

**Step 4: Run UI tests and verify RED**

**Step 5: Implement screens 1c, 1e, 1f, and 1g**

Use native scroll, search, menus, sheets, and controls while matching the edited spacing and styling.

**Step 6: Run view-model and UI tests**

**Step 7: Commit**

```bash
git add Ladle/Library Ladle/App LadleTests LadleUITests
git commit -m "feat: build recipe library and filters"
```

### Task 8: Implement add, demo imports, duplicates, and recovery

**Files:**

- Create: `Ladle/Import/ImportService.swift`
- Create: `Ladle/Import/DemoImportService.swift`
- Create: `Ladle/Import/ImportCoordinator.swift`
- Create: `Ladle/Import/AddRecipeSheet.swift`
- Create: `Ladle/Import/FailedImportSheet.swift`
- Create: `Ladle/Import/CorrectionNotesView.swift`
- Create: `LadleTests/DemoImportServiceTests.swift`
- Create: `LadleTests/ImportCoordinatorTests.swift`
- Create: `LadleUITests/ImportFlowTests.swift`
- Modify: `Ladle/Library/LibraryView.swift`

**Step 1: Write failing demo-service tests**

Use URL slugs to deterministically return ready, needs-review, failed, and slow-parsing outcomes. Verify cancellation does not mutate repository state.

**Step 2: Verify RED, implement the service, and verify GREEN**

**Step 3: Write failing coordinator tests**

Cover supported URLs, unsupported sources, malformed URLs, duplicates, guest limit, retry, pasted details, correction notes, and re-import isolation.

**Step 4: Implement the coordinator and verify GREEN**

Use an injected `Clock` so asynchronous transitions are instant in tests.

**Step 5: Write failing import UI tests**

Test screen 1h add actions, duplicate choice, parsing card, failed sheet screen 1d, and successful navigation to the created recipe.

**Step 6: Implement the edited sheets and hook them to the library**

**Step 7: Run all import tests**

**Step 8: Commit**

```bash
git add Ladle/Import Ladle/Library LadleTests LadleUITests
git commit -m "feat: add resilient local recipe imports"
```

### Task 9: Implement recipe detail and nutrition

**Files:**

- Create: `Ladle/RecipeDetail/RecipeDetailView.swift`
- Create: `Ladle/RecipeDetail/RecipeMetadataBand.swift`
- Create: `Ladle/RecipeDetail/IngredientList.swift`
- Create: `Ladle/RecipeDetail/MethodList.swift`
- Create: `Ladle/Nutrition/NutritionView.swift`
- Create: `LadleUITests/RecipeDetailTests.swift`
- Modify: `Ladle/Library/LibraryView.swift`

**Step 1: Write failing detail UI tests**

Open the orzo fixture and assert contained hero image, title, attribution, time/servings/calories, Start Cooking, ingredients, method, estimate explanation, and secondary actions.

**Step 2: Run and verify RED**

**Step 3: Implement screens 1k and 1l**

Use `NavigationStack`, semantic sections, and accessible estimate/uncertainty labels. Keep nutrition subordinate to normal recipe detail.

**Step 4: Verify detail and nutrition tests**

**Step 5: Commit**

```bash
git add Ladle/RecipeDetail Ladle/Nutrition Ladle/Library LadleUITests
git commit -m "feat: add editorial recipe detail and nutrition"
```

### Task 10: Add explicit HealthKit export

**Files:**

- Create: `Ladle/Health/HealthService.swift`
- Create: `Ladle/Health/HealthKitService.swift`
- Create: `Ladle/Health/HealthExportViewModel.swift`
- Create: `Ladle/Health/HealthExportSheet.swift`
- Create: `LadleTests/HealthExportViewModelTests.swift`
- Create: `LadleUITests/HealthExportTests.swift`
- Modify: `Ladle/Nutrition/NutritionView.swift`

**Step 1: Write failing payload and permission tests**

With a fake `HealthService`, verify no permission request occurs before confirmation, selected servings scale all values, denial is nonfatal, and a successful write reports exactly what was exported.

**Step 2: Verify RED, implement the view model, and verify GREEN**

**Step 3: Write failing UI test**

Assert the serving stepper, explanatory copy, values to be written, and explicit confirmation action from screen 1m.

**Step 4: Implement the sheet and HealthKit adapter**

Request only dietary quantity types supported by HealthKit. Never export automatically.

**Step 5: Run unit and UI tests**

**Step 6: Commit**

```bash
git add Ladle/Health Ladle/Nutrition LadleTests LadleUITests Config/Ladle.entitlements
git commit -m "feat: add intentional Apple Health export"
```

### Task 11: Add structured editing and safe re-import

**Files:**

- Create: `Ladle/Edit/RecipeDraft.swift`
- Create: `Ladle/Edit/RecipeEditorViewModel.swift`
- Create: `Ladle/Edit/RecipeEditorView.swift`
- Create: `Ladle/Edit/ReimportSheet.swift`
- Create: `LadleTests/RecipeEditorViewModelTests.swift`
- Create: `LadleUITests/EditAndReimportTests.swift`
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`

**Step 1: Write failing editor tests**

Verify draft creation, structured field edits, ingredient and step ordering, inline validation, cancel without persistence, and save with preserved stable ID.

**Step 2: Verify RED, implement draft/view model, and verify GREEN**

**Step 3: Write failing re-import safety tests**

Assert current recipe remains fetchable during parsing and after failure; it is replaced only after an explicitly successful candidate.

**Step 4: Implement candidate-based re-import and verify GREEN**

**Step 5: Write failing UI tests**

Cover screen 1n section navigation, saving an edited title, screen 1o notes submission, and failed candidate preservation.

**Step 6: Implement editor and re-import sheets**

**Step 7: Run editor and import regression suites**

**Step 8: Commit**

```bash
git add Ladle/Edit Ladle/RecipeDetail LadleTests LadleUITests
git commit -m "feat: add structured editing and safe reimport"
```

### Task 12: Implement Full Recipe and Focus cooking modes

**Files:**

- Create: `Ladle/Cooking/CookingViewModel.swift`
- Create: `Ladle/Cooking/FullRecipeView.swift`
- Create: `Ladle/Cooking/FocusModeView.swift`
- Create: `Ladle/Cooking/RecipeTimer.swift`
- Create: `Ladle/Cooking/ScreenAwakeController.swift`
- Create: `LadleTests/CookingViewModelTests.swift`
- Create: `LadleUITests/CookingModeTests.swift`
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift`

**Step 1: Write failing view-model tests**

Verify mode switching, shared step position, checkmarks, timer start/pause/reset, clamped navigation, and screen-awake restoration after exit.

**Step 2: Verify RED, implement the view model, and verify GREEN**

Inject the idle-timer adapter and clock.

**Step 3: Write failing UI tests**

Assert Full Recipe screen 1p content, Focus Mode screen 1q content, arm’s-length typography identifiers, relevant ingredients, swipe/tap navigation, and preserved position on return.

**Step 4: Implement both edited cooking modes**

Detected timers use local notifications only after explicit taps. Keep screen awake is explicit and scoped to the presented cooking view.

**Step 5: Run cooking tests**

**Step 6: Commit**

```bash
git add Ladle/Cooking Ladle/RecipeDetail LadleTests LadleUITests
git commit -m "feat: add full and focus cooking modes"
```

### Task 13: Build the Share Extension and App Group queue

**Files:**

- Create: `Packages/LadleCore/Sources/LadleCore/SharedImportEnvelope.swift`
- Create: `Packages/LadleCore/Sources/LadleCore/SharedImportQueue.swift`
- Create: `Packages/LadleCore/Tests/LadleCoreTests/SharedImportQueueTests.swift`
- Create: `LadleShare/ShareViewController.swift`
- Create: `LadleShare/ShareConfirmationView.swift`
- Create: `LadleShare/ShareURLExtractor.swift`
- Create: `LadleTests/ShareURLExtractorTests.swift`
- Create: `Ladle/Import/SharedQueueReconciler.swift`
- Create: `LadleTests/SharedQueueReconcilerTests.swift`
- Modify: `Ladle/App/LadleApp.swift`

**Step 1: Write failing queue tests**

Use a temporary directory and verify atomic enqueue, dequeue, duplicate envelope IDs, malformed-record quarantine, and preservation after a simulated interrupted write.

**Step 2: Verify RED, implement file-backed queue, and verify GREEN**

Use one Codable envelope per file and atomic replacement in the App Group directory.

**Step 3: Write failing URL extraction tests**

Cover direct URL providers, plain-text URLs, multiple attachments, unsupported schemes, and no URL.

**Step 4: Implement extraction and verify GREEN**

**Step 5: Write failing reconciliation tests**

Verify shared jobs enter SwiftData exactly once and remain queued if repository persistence fails.

**Step 6: Implement reconciliation and verify GREEN**

**Step 7: Implement screen 1b**

Host `ShareConfirmationView` in the extension, enqueue before showing success, and call `completeRequest` after the brief confirmation without waiting for parsing.

**Step 8: Build the extension and inspect embedding**

Run:

```bash
xcodebuild build -project Ladle.xcodeproj -scheme Ladle -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
find ~/Library/Developer/Xcode/DerivedData -path '*Ladle.app/PlugIns/LadleShare.appex' -print -quit
```

Expected: app build succeeds and the embedded `.appex` is found.

**Step 9: Commit**

```bash
git add Packages/LadleCore LadleShare Ladle/Import Ladle/App LadleTests Config
git commit -m "feat: add durable share extension imports"
```

### Task 14: Add accessibility, notification behavior, and edge-case polish

**Files:**

- Create: `Ladle/Notifications/NotificationService.swift`
- Create: `Ladle/Notifications/UserNotificationService.swift`
- Create: `LadleTests/NotificationServiceTests.swift`
- Modify: feature views under `Ladle/`
- Modify: `LadleUITests/*.swift`

**Step 1: Write failing notification tests**

Verify notifications are requested in context, only ready imports schedule completion notices, and denial does not affect repository state.

**Step 2: Implement and verify notification behavior**

**Step 3: Add failing accessibility assertions**

For each primary screen, verify unique labels, button traits, import-status text, estimate language, timer values, and 44-point hit regions where XCUITest can inspect frames.

**Step 4: Implement accessibility and Reduce Motion behavior**

**Step 5: Run all tests with large content size**

Launch UI tests with:

```swift
app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"]
```

Expected: primary actions remain hittable and text is not replaced by unlabeled controls.

**Step 6: Commit**

```bash
git add Ladle LadleTests LadleUITests
git commit -m "feat: polish Ladle accessibility and notifications"
```

### Task 15: Perform full verification and visual comparison

**Files:**

- Create: `README.md`
- Create: `docs/verification/2026-07-23-ladle-v1.md`
- Modify: any files required by verified defects

**Step 1: Run formatting and repository checks**

```bash
git diff --check
swift package dump-package --package-path Packages/LadleCore >/dev/null
```

Expected: both commands exit 0.

**Step 2: Run all domain tests**

```bash
swift test --package-path Packages/LadleCore
```

Expected: 0 failures.

**Step 3: Run all app and UI tests**

```bash
xcodebuild test -project Ladle.xcodeproj -scheme Ladle -destination 'platform=iOS Simulator,name=iPhone 17'
```

Expected: `** TEST SUCCEEDED **`.

**Step 4: Build the complete product**

```bash
xcodebuild clean build -project Ladle.xcodeproj -scheme Ladle -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `** BUILD SUCCEEDED **`.

**Step 5: Capture key simulator screens**

Capture welcome, pending library, grid, list, filters, failed recovery, detail, nutrition, Health export, editor, re-import, Full Recipe, and Focus Mode. Compare them at the supplied 402-by-874 reference size.

**Step 6: Correct visual or behavioral discrepancies test-first**

For behavioral defects, add a failing regression test before changing production code. For pure spacing/color adjustments, record the before/after observation in the verification document.

**Step 7: Write the README and verification record**

Document:

- Xcode 26.5 requirement;
- `xcodegen generate`;
- simulator build/test commands;
- demo URLs and deterministic outcomes;
- App Group and HealthKit signing requirements for a real device;
- deferred backend endpoints;
- verification results and remaining external dependencies.

**Step 8: Re-run the complete verification commands**

Only record success after fresh outputs show zero failures.

**Step 9: Commit**

```bash
git add README.md docs Ladle Packages LadleShare LadleTests LadleUITests project.yml Ladle.xcodeproj
git commit -m "docs: verify Ladle native v1"
```
