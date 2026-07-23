import XCTest

@MainActor
final class HealthExportTests: XCTestCase {
    func testHealthExportRequiresServingReviewAndExplicitConfirmation() {
        let app = launchApp()
        openNutrition(in: app)

        let exportButton = app.buttons["Export to Apple Health"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 2))
        exportButton.tap()

        XCTAssertTrue(
            element(in: app, identifier: "health.export")
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["Add nutrition to Apple Health"].exists
        )
        XCTAssertTrue(app.steppers["Servings to export"].exists)
        XCTAssertTrue(app.staticTexts["1 serving"].exists)
        XCTAssertTrue(app.staticTexts["What will be written"].exists)
        XCTAssertTrue(app.staticTexts["≈ 520 kcal"].exists)
        XCTAssertTrue(app.staticTexts["22 g"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Apple will ask for permission only after you confirm. Ladle never exports nutrition automatically."
            ].exists
        )
        XCTAssertTrue(app.buttons["Confirm & Export"].exists)

        app.steppers["Servings to export"]
            .buttons["Increment"]
            .tap()

        XCTAssertTrue(app.staticTexts["1.5 servings"].exists)
        XCTAssertTrue(app.staticTexts["≈ 780 kcal"].exists)
        XCTAssertTrue(app.staticTexts["33 g"].exists)
        capture("Apple Health export values", in: app)

        let confirmButton = app.buttons["Confirm & Export"]
        for _ in 0..<3 where !confirmButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(confirmButton.isHittable)
        capture("Apple Health export confirmation", in: app)
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

    private func openNutrition(in app: XCUIApplication) {
        app.swipeUp()
        let card = element(
            in: app,
            identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
        )
        XCTAssertTrue(card.waitForExistence(timeout: 2))
        card.tap()

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
