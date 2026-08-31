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

    func testInitialLoadFailureBlocksEveryWorkspaceTab() {
        let presentation = LibraryWorkspacePresentation(
            loadState: .failed("Your recipes couldn’t be loaded."),
            reloadErrorMessage: nil
        )

        XCTAssertEqual(
            presentation,
            .blockingFailure("Your recipes couldn’t be loaded.")
        )
        XCTAssertFalse(presentation.displaysTabs)
    }

    func testReloadFailureKeepsEveryWorkspaceTabAvailable() {
        let presentation = LibraryWorkspacePresentation(
            loadState: .loaded,
            reloadErrorMessage: "Your recipes couldn’t be refreshed."
        )

        XCTAssertEqual(
            presentation,
            .content(reloadError: "Your recipes couldn’t be refreshed.")
        )
        XCTAssertTrue(presentation.displaysTabs)
    }

    func testDiscoverRecipeDestinationIsReadOnly() {
        let destination = LibraryRecipeDestination(
            recipe: PreviewFixtures.recipes[0],
            statusText: "Discover recipe",
            access: .discover
        )

        XCTAssertEqual(destination.access, .discover)
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

    func testVideoEmbedBuildsInlinePlayerURLsForEveryVideoSource() {
        XCTAssertEqual(
            VideoEmbed.embedURL(
                for: URL(
                    string: "https://www.tiktok.com/@cook/video/7612708181004799263"
                )!,
                source: .tiktok
            ),
            URL(
                string:
                    "https://www.tiktok.com/player/v1/7612708181004799263?controls=1&progress_bar=0&volume_control=0&fullscreen_button=0&timestamp=0&closed_caption=0&rel=0&native_context_menu=0"
            )
        )
        XCTAssertEqual(
            VideoEmbed.embedURL(
                for: URL(
                    string: "https://www.youtube.com/watch?v=M7lc1UVf-VE"
                )!,
                source: .youtube
            ),
            URL(
                string:
                    "https://www.youtube.com/embed/M7lc1UVf-VE?playsinline=1&rel=0"
            )
        )
        XCTAssertEqual(
            VideoEmbed.embedURL(
                for: URL(
                    string: "https://www.instagram.com/reel/DbbHIKHM3xr/"
                )!,
                source: .instagram
            ),
            URL(
                string:
                    "https://www.instagram.com/reel/DbbHIKHM3xr/embed/"
            )
        )
    }

    func testVideoEmbedNeverFallsBackToTheOriginalBrowserPage() {
        var recipe = PreviewFixtures.recipes[0]
        recipe.originalURL = URL(string: "https://example.com/not-a-video")!

        XCTAssertNil(VideoEmbed.url(for: recipe))
        XCTAssertEqual(VideoEmbed.unavailableTitle, "Video unavailable")
        XCTAssertEqual(
            VideoEmbed.unavailableMessage,
            "This saved link doesn’t contain a playable video ID."
        )
    }
}
