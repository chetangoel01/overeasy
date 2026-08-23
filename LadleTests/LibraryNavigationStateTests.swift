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

    func testSelectingDiscoverDoesNotPushNavigation() {
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

        state.select(.discover)

        XCTAssertEqual(state.tab, .discover)
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

    func testEveryWorkspaceTabKeepsAccountInItsToolbar() {
        for tab in LibraryTab.allCases {
            XCTAssertTrue(
                tab.toolbarActions.contains(.account),
                "Expected account action on \(tab)"
            )
        }
        XCTAssertEqual(
            LibraryTab.recipes.toolbarActions,
            [.account, .addRecipe]
        )
        XCTAssertEqual(LibraryTab.discover.toolbarActions, [.account])
        XCTAssertEqual(LibraryTab.watch.toolbarActions, [.account])
        XCTAssertEqual(LibraryTab.inbox.toolbarActions, [.account])
    }

    func testDiscoverRecipeDestinationIsReadOnly() {
        let destination = LibraryRecipeDestination(
            recipe: PreviewFixtures.recipes[0],
            statusText: "Discover recipe",
            access: .discover
        )

        XCTAssertFalse(destination.allowsLibraryEdits)
    }

    func testRecipeContextMenuOffersOpenAndFavoriteActions() {
        var recipe = PreviewFixtures.recipes[0]
        recipe.isFavorite = false
        let presentation = RecipeContextMenuPresentation(
            recipe: recipe
        )

        XCTAssertEqual(presentation.actions, [.open, .toggleFavorite])
        XCTAssertEqual(presentation.openTitle, "Open Recipe")
        XCTAssertEqual(presentation.favoriteTitle, "Add to Favorites")
    }
}
