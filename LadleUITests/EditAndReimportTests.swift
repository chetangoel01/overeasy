import XCTest

@MainActor
final class EditAndReimportTests: XCTestCase {
    func testEditorShowsStructuredSectionsAndSavesTitle() {
        let app = launchApp()
        openOrzoRecipe(in: app)
        openRecipeOption("Edit recipe", in: app)

        XCTAssertTrue(
            element(in: app, identifier: "recipe.editor")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Edit recipe"].exists)
        XCTAssertTrue(app.buttons["Basics section"].exists)
        XCTAssertTrue(app.buttons["Timing section"].exists)
        XCTAssertTrue(app.buttons["Ingredients section"].exists)
        XCTAssertTrue(app.buttons["Method section"].exists)
        XCTAssertTrue(app.buttons["Nutrition section"].exists)

        let titleField = app.textFields["Recipe title"]
        XCTAssertTrue(titleField.exists)
        app.buttons["Clear Recipe title"].tap()
        titleField.tap()
        titleField.typeText("One-Pot Lemon Orzo with Feta — Edited")
        capture("Structured recipe editor", in: app)

        app.buttons["Save recipe"].tap()

        XCTAssertTrue(
            app.staticTexts[
                "One-Pot Lemon Orzo with Feta — Edited"
            ]
            .waitForExistence(timeout: 2)
        )
    }

    func testReimportAcceptsNotesAndReplacesOnlyOnSuccess() {
        let app = launchApp()
        openOrzoRecipe(in: app)
        openRecipeOption("Re-import from source", in: app)

        XCTAssertTrue(
            element(in: app, identifier: "recipe.reimport")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Re-import safely"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Your current recipe stays available until the replacement is ready."
            ].exists
        )
        XCTAssertTrue(
            app.staticTexts["https://example.com/lemon-orzo"].exists
        )

        let notes = app.textViews["Correction notes"]
        notes.tap()
        notes.typeText("Keep the lemon bright.")
        app.buttons["Start safe re-import"].tap()

        XCTAssertTrue(
            app.staticTexts["Updated recipe ready"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"].exists
        )
    }

    func testFailedReimportExplicitlyPreservesCurrentRecipe() {
        let app = launchApp()
        openOrzoRecipe(in: app)
        openRecipeOption("Re-import from source", in: app)

        let notes = app.textViews["Correction notes"]
        XCTAssertTrue(notes.waitForExistence(timeout: 2))
        notes.tap()
        notes.typeText("simulate failure")
        app.buttons["Start safe re-import"].tap()

        XCTAssertTrue(
            app.staticTexts["Current recipe is safe"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"].exists
        )
        XCTAssertTrue(app.buttons["Try re-import again"].exists)
        capture("Safe re-import failure", in: app)
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

    private func openOrzoRecipe(in app: XCUIApplication) {
        app.swipeUp()
        let card = element(
            in: app,
            identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
        )
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()
        XCTAssertTrue(
            element(in: app, identifier: "recipe.detail")
                .waitForExistence(timeout: 2)
        )
    }

    private func openRecipeOption(
        _ title: String,
        in app: XCUIApplication
    ) {
        let button = app.buttons[title]
        for _ in 0..<6 where !button.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
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
