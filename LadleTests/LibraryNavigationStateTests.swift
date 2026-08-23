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
                        statusText: "Check details"
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
                        statusText: "Check details"
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
