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

    /// The point of the shared model, and of asking the question once: a
    /// diet given during onboarding is already true on every tab, without a
    /// second control and without choosing it again. Recipes answers it from
    /// its own decoded tags; Discover asks the server. Neither is visible
    /// from here — only that they agree.
    @MainActor
    func testADietChosenDuringOnboardingIsAlreadyOnEveryTab() throws {
        let app = launchOnboardingDietStep()
        chooseVegetarian(in: app)

        // The launch lands on Discover, which asked the server with the diet
        // the cook had given it a second earlier.
        XCTAssertTrue(
            app.buttons["Remove filter: Vegetarian diet"]
                .waitForExistence(timeout: 5),
            "Discover reads the diet the onboarding step wrote"
        )
        XCTAssertFalse(
            app.staticTexts["Crispy Chili Oil Smash Burgers"]
                .waitForExistence(timeout: 2),
            "The feed came back filtered; the meat dish is not in it"
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"].exists,
            "The vegetarian sources are still there"
        )

        app.tabBars.buttons["Recipes"].tap()

        // Four of the demo's six dishes are vegetarian.
        XCTAssertTrue(
            app.staticTexts["4 recipes"].waitForExistence(timeout: 5),
            "The library narrows on the tags it already holds"
        )
    }

    /// What the filter menu may still do to a diet: put it down for the
    /// evening. It is the one filter that comes back by itself, because the
    /// cook did not set it there and should not have to remember to.
    @MainActor
    func testPausingTheDietShowsEverythingAndItIsBackNextLaunch() throws {
        let app = launchOnboardingDietStep()
        chooseVegetarian(in: app)
        openRecipes(in: app)

        XCTAssertTrue(
            app.staticTexts["4 recipes"].waitForExistence(timeout: 5)
        )

        filterMenu(in: app).tap()
        let onRow = app.buttons["Vegetarian diet · On"]
        XCTAssertTrue(
            onRow.waitForExistence(timeout: 3),
            "The menu says which diet is on rather than offering five to pick"
        )
        onRow.tap()

        XCTAssertTrue(
            app.staticTexts["6 recipes"].waitForExistence(timeout: 3),
            "A paused diet shows the whole library again"
        )
        XCTAssertFalse(
            app.buttons["Remove filter: Vegetarian diet"].exists,
            "Nothing is narrowing the library, so there is no pill"
        )

        // "Showing everything" has to be true of the tabs that ask the
        // server too, not only of the library that answers locally.
        app.tabBars.firstMatch.buttons["Discover"].tap()
        XCTAssertTrue(
            app.staticTexts["Crispy Chili Oil Smash Burgers"]
                .waitForExistence(timeout: 5),
            "A pause is a filter change: Discover fetched again without it"
        )
        app.tabBars.firstMatch.buttons["Recipes"].tap()

        filterMenu(in: app).tap()
        let offRow = app.buttons["Vegetarian diet · Off, showing everything"]
        XCTAssertTrue(
            offRow.waitForExistence(timeout: 3),
            "The row still names the diet, so the pause can be lifted"
        )
        offRow.tap()
        XCTAssertTrue(
            app.staticTexts["4 recipes"].waitForExistence(timeout: 3)
        )

        // Put it down again, then relaunch without the preferences reset:
        // the diet is stored, the pause is not.
        filterMenu(in: app).tap()
        app.buttons["Vegetarian diet · On"].tap()
        XCTAssertTrue(
            app.staticTexts["6 recipes"].waitForExistence(timeout: 3)
        )

        app.launchArguments = ["-ui-testing", "-onboarding-complete"]
        app.launch()
        openRecipes(in: app)

        XCTAssertTrue(
            app.staticTexts["4 recipes"].waitForExistence(timeout: 5),
            "A pause dies with the launch; the diet does not"
        )
    }

    /// Ingredients is the one part of the control a menu cannot draw, so it
    /// borrows a system alert. Driven from Discover, which is the harder of
    /// the two placements: the menu lives in the navigation bar there, and
    /// an alert presented from a toolbar item is the thing worth proving.
    @MainActor
    func testAnIngredientTermIsTypedIntoTheControlAndNarrowsDiscover() throws {
        let app = launchApp(startingOn: "Discover")

        XCTAssertTrue(
            app.staticTexts["Crispy Chili Oil Smash Burgers"]
                .waitForExistence(timeout: 5)
        )

        app.buttons["Filters"].tap()
        let ingredients = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Ingredients'")
        ).firstMatch
        XCTAssertTrue(ingredients.waitForExistence(timeout: 2))
        ingredients.tap()

        let add = app.buttons["Add ingredient…"]
        XCTAssertTrue(add.waitForExistence(timeout: 2))
        add.tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 2),
            "Add ingredient… opens an alert with one field"
        )
        field.typeText("gochujang")
        app.alerts.buttons["Add"].tap()

        XCTAssertTrue(
            app.buttons["Remove filter: With gochujang"]
                .waitForExistence(timeout: 3),
            "The term becomes a pill like every other filter"
        )
        XCTAssertTrue(
            app.staticTexts["Sheet-Pan Gochujang Chicken"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.staticTexts["Crispy Chili Oil Smash Burgers"].exists,
            "The feed came back without the sources that do not list it"
        )

        app.buttons["Remove filter: With gochujang"].tap()
        XCTAssertTrue(
            app.staticTexts["Crispy Chili Oil Smash Burgers"]
                .waitForExistence(timeout: 3)
        )
    }

    /// Watch draws the control in its own overlay rather than a navigation
    /// bar, so the alert presents from a different place. The one path with
    /// no other coverage.
    @MainActor
    func testTheControlAndItsAlertAlsoWorkFromWatchsOverlay() throws {
        let app = launchApp(startingOn: "Watch")

        let filters = app.buttons["library.watch.filter"]
        XCTAssertTrue(
            filters.waitForExistence(timeout: 5),
            "Watch carries the same control in its one band of chrome"
        )
        filters.tap()

        let ingredients = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Ingredients'")
        ).firstMatch
        XCTAssertTrue(ingredients.waitForExistence(timeout: 2))
        ingredients.tap()

        let add = app.buttons["Add ingredient…"]
        XCTAssertTrue(add.waitForExistence(timeout: 2))
        add.tap()

        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(
            field.waitForExistence(timeout: 2),
            "The alert presents over the video feed too"
        )
        field.typeText("nothing-matches-this")
        app.alerts.buttons["Add"].tap()

        // Watch has no header to hang a pill from, so the empty state is
        // where the filter has to show — and it has to offer the way out.
        XCTAssertTrue(
            app.buttons["Clear filters"].waitForExistence(timeout: 5),
            "An emptied feed says what emptied it and offers to clear it"
        )
        app.buttons["Clear filters"].tap()
        XCTAssertTrue(
            app.buttons["Clear filters"].waitForNonExistence(timeout: 5)
        )
    }

    /// The one launch that is stopped by the diet question. Every other test
    /// in the bundle passes `-onboarding-complete` alone, which answers it.
    @MainActor
    private func launchOnboardingDietStep() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-diet-step-pending",
            "-reset-library-preferences",
        ]
        app.launch()
        XCTAssertTrue(
            app.staticTexts["Do you follow a diet?"]
                .waitForExistence(timeout: 5),
            "A new cook is asked about their diet before the library"
        )
        return app
    }

    @MainActor
    private func chooseVegetarian(in app: XCUIApplication) {
        app.buttons["diet-step.option.vegetarian"].tap()
        app.buttons["diet-step.continue"].tap()

        // A cook who has just said they are vegetarian is asked, once,
        // whether they would rather not carry an egg. Every launch here
        // resets preferences, so the question is always waiting when the
        // library arrives; these tests are about the diet, and keep the egg.
        let offer = app.alerts["Prefer an icon without the egg?"]
        XCTAssertTrue(
            offer.waitForExistence(timeout: 10),
            "A vegetarian diet raises the icon question on the way in"
        )
        offer.buttons["Keep the egg"].tap()
    }

    /// Onboarding fades the library in underneath itself, so for a moment
    /// there are two tab bars on screen and the query behind a bare
    /// subscript matches twice. Wait for the feed the launch lands on, then
    /// take the first.
    @MainActor
    private func openRecipes(in app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["library.discover"]
                .waitForExistence(timeout: 10),
            "Answering the diet question lands the cook in the app"
        )
        app.tabBars.firstMatch.buttons["Recipes"].tap()
    }

    /// The filter button's label carries how many filters are on, so a diet
    /// changes it. Matched on the word rather than the count.
    @MainActor
    private func filterMenu(in app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Filters'")
        ).firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 3))
        return menu
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
