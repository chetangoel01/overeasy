import XCTest

@MainActor
final class RecipeDetailTests: XCTestCase {
    func testRecipeDetailShowsEditorialCookingInformation() {
        let app = launchApp()
        openOrzoRecipe(in: app)

        XCTAssertTrue(
            element(in: app, identifier: "recipe.detail")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"].exists
        )
        XCTAssertTrue(app.staticTexts["@miacooks"].exists)
        XCTAssertTrue(app.staticTexts["Instagram"].exists)
        XCTAssertTrue(app.staticTexts["35 min"].exists)
        XCTAssertTrue(app.staticTexts["4 servings"].exists)
        XCTAssertTrue(app.staticTexts["≈ 520 cal"].exists)
        XCTAssertTrue(app.buttons["Start Cooking"].exists)
        capture("Recipe detail — editorial header", in: app)

        app.swipeUp()

        XCTAssertTrue(app.staticTexts["Ingredients"].exists)
        XCTAssertTrue(app.staticTexts["1 cup orzo"].exists)
        XCTAssertTrue(app.staticTexts["Method"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Toast the orzo with garlic until the edges turn golden."
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Estimated nutrition"].exists)
        capture("Recipe detail — ingredients and method", in: app)

        app.swipeUp()

        XCTAssertTrue(app.buttons["Edit recipe"].exists)
        XCTAssertTrue(app.buttons["Re-import from source"].exists)
        XCTAssertTrue(app.buttons["View nutrition"].exists)
        XCTAssertTrue(app.buttons["Watch original video"].exists)
        XCTAssertTrue(
            app.buttons[
                "Add One-Pot Lemon Orzo with Feta to favorites"
            ].exists
        )
    }

    func testNutritionSheetKeepsEstimateAndServingBasisVisible() {
        let app = launchApp()
        openOrzoRecipe(in: app)

        let nutritionButton = app.buttons["View nutrition"]
        for _ in 0..<5 where !nutritionButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(nutritionButton.waitForExistence(timeout: 2))
        nutritionButton.tap()

        XCTAssertTrue(
            element(in: app, identifier: "nutrition.detail")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Nutrition"].exists)
        XCTAssertTrue(app.staticTexts["≈ 520"].exists)
        XCTAssertTrue(app.staticTexts["Calories"].exists)
        XCTAssertTrue(app.staticTexts["Protein"].exists)
        XCTAssertTrue(app.staticTexts["22 g"].exists)
        XCTAssertTrue(app.staticTexts["Carbohydrates"].exists)
        XCTAssertTrue(app.staticTexts["48 g"].exists)
        XCTAssertTrue(app.staticTexts["Fat"].exists)
        XCTAssertTrue(app.staticTexts["24 g"].exists)
        XCTAssertTrue(app.staticTexts["Per 1 serving"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Nutrition is estimated from the imported recipe."
            ].exists
        )
        capture("Recipe detail — nutrition", in: app)
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
