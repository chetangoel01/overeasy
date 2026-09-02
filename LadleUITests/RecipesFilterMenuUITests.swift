import XCTest

/// The Recipes filter menu, driven end to end: choose a value, watch the
/// library narrow, then take the filter off with its pill. The sheet this
/// replaced never had a UI test, which is how it drifted from the header
/// around it.
final class RecipesFilterMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testFilteringByTimeNarrowsTheLibraryAndThePillClearsIt() throws {
        let app = launchApp(startingOn: "Recipes")

        let count = app.staticTexts["6 recipes"]
        XCTAssertTrue(
            count.waitForExistence(timeout: 5),
            "The demo library starts at six recipes"
        )

        app.buttons["Filters"].tap()
        timeSubmenu(in: app).tap()

        let option = app.buttons["30 min or less"]
        XCTAssertTrue(
            option.waitForExistence(timeout: 2),
            "Time offers its options as picker rows"
        )
        option.tap()

        // 25, 15 and 10 minutes of the demo library's 25/35/15/45/10/40.
        XCTAssertTrue(
            app.staticTexts["3 recipes"].waitForExistence(timeout: 3),
            "Choosing a time applies at once, with no Apply to press"
        )

        let pill = app.buttons["Remove filter: 30 min or less"]
        XCTAssertTrue(
            pill.waitForExistence(timeout: 2),
            "The active filter shows as a pill named the way the menu named it"
        )
        pill.tap()

        XCTAssertTrue(
            app.staticTexts["6 recipes"].waitForExistence(timeout: 3),
            "Removing the pill restores the whole library"
        )
        XCTAssertFalse(app.buttons["Remove filter: 30 min or less"].exists)
    }

    /// The submenu's label carries its current value, so it is matched on its
    /// leading dimension name rather than on the whole string.
    @MainActor
    private func timeSubmenu(in app: XCUIApplication) -> XCUIElement {
        let submenu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Time'")
        ).firstMatch
        XCTAssertTrue(
            submenu.waitForExistence(timeout: 3),
            "The filter menu offers a Time submenu"
        )
        return submenu
    }

    /// A launch lands on Discover, so a test about another tab has to ask for
    /// it rather than assume the first screen is its own.
    @MainActor
    private func launchApp(startingOn tab: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()
        let button = app.tabBars.buttons[tab]
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "Expected the \(tab) tab after launch"
        )
        button.tap()
        return app
    }
}
