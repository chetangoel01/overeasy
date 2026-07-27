import XCTest

@MainActor
final class CookingModeTests: XCTestCase {
    func testFullRecipeModeShowsCheckableCookingWorkspace() {
        let app = launchCooking()

        XCTAssertTrue(
            element(in: app, identifier: "cooking.full-recipe")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].exists)
        XCTAssertTrue(app.switches["Keep screen awake"].exists)
        XCTAssertTrue(app.buttons["Focus mode"].exists)
        XCTAssertTrue(app.buttons["Mark orzo complete"].exists)
        XCTAssertTrue(
            app.buttons[
                "Mark step 1 complete, Toast the orzo with garlic until the edges turn golden."
            ].exists
        )
        XCTAssertTrue(
            app.buttons["Start Simmer orzo timer, 12:00"].exists
        )
        capture("Full Recipe cooking mode", in: app)

        app.buttons["Mark orzo complete"].tap()
        XCTAssertTrue(app.buttons["Mark orzo incomplete"].exists)
    }

    func testFocusModeUsesRelevantIngredientsAndPreservesPosition() {
        let app = launchCooking()
        let focusButton = app.buttons["Focus mode"]
        XCTAssertTrue(focusButton.waitForExistence(timeout: 2))
        focusButton.tap()

        let focusRoot = element(
            in: app,
            identifier: "cooking.focus-mode"
        )
        XCTAssertTrue(focusRoot.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Back to full recipe"].exists)
        XCTAssertTrue(app.staticTexts["Step 1"].exists)
        XCTAssertTrue(
            element(in: app, identifier: "focus.step.large").exists
        )
        XCTAssertTrue(app.staticTexts["Step 1 of 4"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Toast the orzo with garlic until the edges turn golden."
            ].exists
        )
        XCTAssertTrue(app.staticTexts["1 cup orzo"].exists)
        XCTAssertTrue(
            app.staticTexts["2 cloves garlic — finely chopped"].exists
        )
        XCTAssertFalse(
            focusRoot.staticTexts["2 cups vegetable stock"].exists
        )
        capture("Focus cooking mode", in: app)

        app.buttons["Next step"].tap()
        XCTAssertTrue(app.staticTexts["Step 2 of 4"].exists)
        XCTAssertTrue(app.staticTexts["2 cups vegetable stock"].exists)
        XCTAssertTrue(
            app.buttons["Start Simmer orzo timer, 12:00"].exists
        )

        app.swipeRight()
        XCTAssertTrue(
            app.staticTexts["Step 1 of 4"]
                .waitForExistence(timeout: 2)
        )
        app.swipeLeft()
        XCTAssertTrue(
            app.staticTexts["Step 2 of 4"]
                .waitForExistence(timeout: 2)
        )

        app.buttons["Back to full recipe"].tap()
        XCTAssertTrue(
            element(in: app, identifier: "cooking.full-recipe")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Step 2 of 4"].exists)
    }

    private func launchCooking() -> XCUIApplication {
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

        app.buttons["All 6"].tap()
        app.swipeUp()
        let card = element(
            in: app,
            identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
        )
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()

        let start = app.buttons["Start Cooking"]
        XCTAssertTrue(start.waitForExistence(timeout: 2))
        start.tap()
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
