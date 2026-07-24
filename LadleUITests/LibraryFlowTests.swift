import XCTest

@MainActor
final class LibraryFlowTests: XCTestCase {
    func testLibraryShowsPendingStatesAndRecipeMetadata() {
        let app = launchApp()

        XCTAssertTrue(app.staticTexts["Parsing"].exists)
        XCTAssertTrue(app.staticTexts["Needs review"].exists)
        XCTAssertTrue(app.staticTexts["Import failed"].exists)
        capture("Library — pending imports", in: app)

        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["35 min"].exists)
        XCTAssertTrue(app.staticTexts["≈ 520 cal"].exists)
        XCTAssertTrue(
            app.buttons[
                "Add One-Pot Lemon Orzo with Feta to favorites"
            ].exists
        )
        capture("Library — recipe grid", in: app)
    }

    func testSearchAndListModeCompose() {
        let app = launchApp()
        let searchField = app.textFields["Search your recipes"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))

        searchField.tap()
        searchField.typeText("orzo")

        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            app.staticTexts["Crispy Chili Oil Smash Burgers"].exists
        )

        app.buttons["Show recipes as a list"].tap()

        XCTAssertEqual(searchField.value as? String, "orzo")
        XCTAssertTrue(
            element(
                in: app,
                identifier: "recipe.list.one-pot-lemon-orzo-with-feta"
            )
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            element(
                in: app,
                identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
            )
                .exists
        )
        if app.keyboards.buttons["Search"].exists {
            app.keyboards.buttons["Search"].tap()
        }
        capture("Library — recipe list", in: app)
    }

    func testMaximumTimeFilterCanBeAppliedAndRemoved() {
        let app = launchApp()

        app.buttons["Filter recipes"].tap()

        let thirtyMinutes = app.buttons["30 minutes or less"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 2))
        capture("Library — filters", in: app)
        thirtyMinutes.tap()
        app.buttons["Apply Filters"].tap()

        let activeFilter = app.buttons["Remove filter: Up to 30 min"]
        XCTAssertTrue(activeFilter.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["15-Minute Garlic Butter Udon"].exists
        )
        XCTAssertFalse(
            app.staticTexts["Sheet-Pan Gochujang Chicken"].exists
        )

        activeFilter.tap()

        XCTAssertFalse(activeFilter.exists)
    }

    func testFavoriteControlUpdatesItsAccessibleState() {
        let app = launchApp()
        app.swipeUp()

        let addFavorite = app.buttons[
            "Add One-Pot Lemon Orzo with Feta to favorites"
        ]
        XCTAssertTrue(addFavorite.waitForExistence(timeout: 2))

        addFavorite.tap()

        XCTAssertTrue(
            app.buttons[
                "Remove One-Pot Lemon Orzo with Feta from favorites"
            ]
            .waitForExistence(timeout: 2)
        )
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 3)
        )
        return app
    }

    private func element(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func capture(
        _ name: String,
        in app: XCUIApplication
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
