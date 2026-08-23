import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class LibraryNavigationStateTests: XCTestCase {
    func testLibraryStartsOnRecipesTab() {
        let state = LibraryNavigationState()

        XCTAssertEqual(state.tab, .recipes)
        XCTAssertTrue(state.path.isEmpty)
    }

    func testSelectingAWorkspaceTabDoesNotPushNavigation() {
        var state = LibraryNavigationState(
            path: [
                .recipe(
                    LibraryRecipeDestination(
                        recipe: PreviewFixtures.recipes[0],
                        statusText: "Saved recipe"
                    )
                ),
            ]
        )

        state.select(.watch)

        XCTAssertEqual(state.tab, .watch)
        XCTAssertTrue(state.path.isEmpty)
    }

    func testCompletedReviewReturnsToInboxWhenActionableItemsRemain() {
        var state = LibraryNavigationState(
            tab: .inbox,
            path: [
                .recipe(
                    LibraryRecipeDestination(
                        recipe: PreviewFixtures.recipes[1],
                        statusText: "Check details"
                    )
                ),
            ]
        )

        state.reviewDidComplete(hasActionableImports: true)

        XCTAssertEqual(state.tab, .inbox)
        XCTAssertTrue(state.path.isEmpty)
    }

    func testCompletedLastReviewReturnsToLibraryRoot() {
        var state = LibraryNavigationState(
            tab: .inbox,
            path: [
                .recipe(
                    LibraryRecipeDestination(
                        recipe: PreviewFixtures.recipes[1],
                        statusText: "Check details"
                    )
                ),
            ]
        )

        state.reviewDidComplete(hasActionableImports: false)

        XCTAssertEqual(state.tab, .recipes)
        XCTAssertTrue(state.path.isEmpty)
    }

    func testInboxCanBeSelectedAgainAfterReturningToRecipes() {
        var state = LibraryNavigationState(tab: .inbox)

        state.reviewDidComplete(hasActionableImports: false)
        state.select(.inbox)

        XCTAssertEqual(state.tab, .inbox)
        XCTAssertTrue(state.path.isEmpty)
    }
}
