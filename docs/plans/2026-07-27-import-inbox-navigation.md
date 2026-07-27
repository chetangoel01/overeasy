# Import Inbox Review Navigation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make successful review completion return to the remaining Import Inbox or Library Home, remove the reviewed row immediately, and keep the inbox entry point reusable.

**Architecture:** Replace the Library's competing optional workspace and recipe destinations with one typed navigation path. Recipe Detail reports a successful review separately from ordinary recipe edits, and LibraryView deterministically rewrites the path from the updated actionable-import count.

**Tech Stack:** Swift 6, SwiftUI `NavigationStack`, Observation, XCTest, XCUITest

---

### Task 1: Specify Library navigation outcomes

**Files:**
- Create: `LadleTests/LibraryNavigationStateTests.swift`
- Modify: `Ladle/Library/LibraryView.swift:4-28`

**Step 1: Write the failing navigation-state tests**

Create `LibraryNavigationStateTests` with three tests:

```swift
import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class LibraryNavigationStateTests: XCTestCase {
    func testCompletedReviewReturnsToInboxWhenActionableItemsRemain() {
        var state = LibraryNavigationState(
            path: [
                .importInbox,
                .recipe(
                    LibraryRecipeDestination(
                        recipe: PreviewFixtures.recipes[1],
                        statusText: "Needs review"
                    )
                ),
            ]
        )

        state.reviewDidComplete(hasActionableImports: true)

        XCTAssertEqual(state.path, [.importInbox])
    }

    func testCompletedLastReviewReturnsToLibraryRoot() {
        var state = LibraryNavigationState(
            path: [
                .importInbox,
                .recipe(
                    LibraryRecipeDestination(
                        recipe: PreviewFixtures.recipes[1],
                        statusText: "Needs review"
                    )
                ),
            ]
        )

        state.reviewDidComplete(hasActionableImports: false)

        XCTAssertTrue(state.path.isEmpty)
    }

    func testImportInboxCanOpenAgainAfterReturningToRoot() {
        var state = LibraryNavigationState(path: [.importInbox])
        state.reviewDidComplete(hasActionableImports: false)

        state.open(.importInbox)

        XCTAssertEqual(state.path, [.importInbox])
    }
}
```

**Step 2: Run the focused test to verify RED**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryNavigationStateTests
```

Expected: compilation fails because `LibraryNavigationState` and its route cases do not exist.

**Step 3: Implement the minimal typed state**

In `LibraryView.swift`, replace `LibraryWorkspaceDestination` with:

```swift
enum LibraryNavigationDestination: Hashable {
    case search
    case importInbox
    case watch
    case recipe(LibraryRecipeDestination)
}

struct LibraryNavigationState: Equatable {
    var path: [LibraryNavigationDestination] = []

    mutating func open(_ destination: LibraryNavigationDestination) {
        path.append(destination)
    }

    mutating func reviewDidComplete(hasActionableImports: Bool) {
        path = hasActionableImports ? [.importInbox] : []
    }
}
```

**Step 4: Run the focused test to verify GREEN**

Run the command from Step 2.

Expected: all three `LibraryNavigationStateTests` pass.

**Step 5: Commit**

```bash
git add Ladle/Library/LibraryView.swift LadleTests/LibraryNavigationStateTests.swift
git commit -m "test: specify import inbox review navigation"
```

### Task 2: Make the typed path own Library navigation

**Files:**
- Modify: `Ladle/Library/LibraryView.swift:12-225`
- Modify: `Ladle/Library/ImportInboxView.swift:1-31`

**Step 1: Write the failing UI regression**

Add `testReviewedImportLeavesInboxAndInboxCanReopen()` to
`LadleUITests/LibraryFlowTests.swift`:

```swift
func testReviewedImportLeavesInboxAndInboxCanReopen() {
    let app = launchApp()
    app.buttons["Home"].tap()
    element(in: app, identifier: "library.import-inbox").tap()

    let reviewJob = element(
        in: app,
        identifier: "import.FD53B35A-4E30-40BE-8D90-047908528102"
    )
    XCTAssertTrue(reviewJob.waitForExistence(timeout: 2))
    reviewJob.tap()

    let completeReview = element(
        in: app,
        identifier: "recipe.complete-review"
    )
    XCTAssertTrue(completeReview.waitForExistence(timeout: 2))
    completeReview.tap()

    XCTAssertTrue(
        element(in: app, identifier: "library.import-inbox.root")
            .waitForExistence(timeout: 2)
    )
    XCTAssertFalse(reviewJob.exists)

    app.buttons["Back"].tap()
    let inbox = element(in: app, identifier: "library.import-inbox")
    XCTAssertTrue(inbox.waitForExistence(timeout: 2))
    inbox.tap()
    XCTAssertTrue(
        element(in: app, identifier: "library.import-inbox.root")
            .waitForExistence(timeout: 2)
    )
}
```

**Step 2: Run the UI regression to verify RED**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleUITests/LibraryFlowTests/testReviewedImportLeavesInboxAndInboxCanReopen
```

Expected: the test remains on Recipe Detail after **Mark reviewed** instead of
returning to Import Inbox.

**Step 3: Replace optional destinations with one path**

In `LibraryView`:

- Replace `workspaceDestination` and `selectedDestination` with
  `@State private var navigation = LibraryNavigationState()`.
- Initialize `NavigationStack(path: $navigation.path)`.
- Replace the two existing destination modifiers with one
  `.navigationDestination(for: LibraryNavigationDestination.self)`.
- Route `.search`, `.importInbox`, `.watch`, and `.recipe` from the switch.
- Change Home, Search, Watch, inbox-review, collection, and pending-sheet
  callbacks to call `navigation.open(...)`.
- Stop replacing the recipe route from `recipeDidChange`; RecipeDetailView
  already owns its current displayed recipe and the callback should only reload
  the Library view model.

Use this destination switch:

```swift
.navigationDestination(for: LibraryNavigationDestination.self) {
    destination in
    switch destination {
    case .search:
        LibrarySearchView(
            viewModel: viewModel,
            openRecipe: openRecipe
        )
    case .importInbox:
        ImportInboxView(
            viewModel: viewModel,
            recoverImport: { failedImportJob = $0 },
            openReview: showRecipe
        )
    case .watch:
        WatchView(
            viewModel: viewModel,
            openRecipe: openRecipe
        )
    case let .recipe(destination):
        recipeDetail(destination)
    }
}
```

In `ImportInboxView`, remove `@Environment(\.dismiss)` and the
actionable-count `onChange`. LibraryView now owns all successful review
navigation.

**Step 4: Run existing navigation tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryNavigationStateTests \
  -only-testing:LadleUITests/LibraryFlowTests/testLibraryShowsPendingStatesAndRecipeMetadata
```

Expected: the unit tests pass and the existing first-open inbox navigation
still passes. The new review UI regression still fails because Recipe Detail
does not report completion yet.

**Step 5: Commit**

```bash
git add Ladle/Library/LibraryView.swift Ladle/Library/ImportInboxView.swift
git commit -m "refactor: unify library navigation path"
```

### Task 3: Route successful review completion

**Files:**
- Modify: `Ladle/RecipeDetail/RecipeDetailView.swift:10-54,310-325`
- Modify: `Ladle/Library/LibraryView.swift:165-225`
- Test: `LadleUITests/LibraryFlowTests.swift`

**Step 1: Add an explicit success callback**

Add `let reviewDidComplete: () -> Void` to `RecipeDetailView`, default it to an
empty closure in the initializer, and invoke it only after `completeReview`
returns a recipe:

```swift
Button("Mark reviewed") {
    guard let reviewed = completeReview(displayedRecipe.id) else {
        return
    }
    reviewIsPending = false
    applyChangedRecipe(reviewed)
    reviewDidComplete()
}
```

Do not invoke the callback when persistence fails.

**Step 2: Handle the callback from LibraryView**

Pass `reviewDidComplete: finishReviewNavigation` when constructing Recipe
Detail, then add:

```swift
private func finishReviewNavigation() {
    let hasActionableImports = !viewModel.actionableImportJobs.isEmpty
    navigation.reviewDidComplete(
        hasActionableImports: hasActionableImports
    )
    if !hasActionableImports {
        section = .home
    }
}
```

Update `showRecipe`, `openRecipe`, and `finishPendingNavigation` to append
`.recipe(...)` to the typed path.

**Step 3: Run the new UI regression to verify GREEN**

Run the command from Task 2, Step 2.

Expected: after **Mark reviewed**, Import Inbox is visible, the reviewed row is
absent, and the inbox can be opened again after returning Home.

**Step 4: Run adjacent focused tests**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests/LibraryNavigationStateTests \
  -only-testing:LadleTests/LibraryViewModelTests/testCompletingReviewClearsRecipeAndInboxReviewStatus \
  -only-testing:LadleUITests/LibraryFlowTests
```

Expected: all focused unit and Library UI tests pass.

**Step 5: Commit**

```bash
git add Ladle/RecipeDetail/RecipeDetailView.swift Ladle/Library/LibraryView.swift LadleUITests/LibraryFlowTests.swift
git commit -m "fix: cleanly finish import inbox reviews"
```

### Task 4: Full verification and iPhone 16 Pro handoff

**Files:**
- Verify: all modified Swift sources and tests
- Update if needed: `docs/verification/2026-07-27-import-inbox-and-dark-mode.md`

**Step 1: Run formatting and diff checks**

Run:

```bash
git diff --check
```

Expected: no output and exit code 0.

**Step 2: Run the complete app unit target**

Run:

```bash
xcodebuild test \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7' \
  -only-testing:LadleTests
```

Expected: the complete `LadleTests` target passes with zero failures.

**Step 3: Build the simulator app**

Run:

```bash
xcodebuild build \
  -project Ladle.xcodeproj \
  -scheme Ladle \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=5CDD8E03-C52C-449A-8332-28F29FF937B7'
```

Expected: `** BUILD SUCCEEDED **`.

**Step 4: Validate the interaction on the dedicated simulator**

Run the Ladle scheme from Xcode on **Overeasy - iPhone 16 Pro** and verify:

1. Import Inbox opens from Home.
2. **Mark reviewed** removes the reviewed row.
3. Remaining actionable imports return the user to Import Inbox.
4. Completing the last actionable review returns the user to Library Home.
5. The Import Inbox entry point opens on every subsequent tap when items exist.
6. A failed review save stays on Recipe Detail and shows the existing error.

**Step 5: Commit verification notes**

```bash
git add docs/verification/2026-07-27-import-inbox-and-dark-mode.md
git commit -m "docs: verify import inbox review navigation"
```

