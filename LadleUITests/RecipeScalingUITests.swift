import XCTest

/// Scaling a recipe from its yield, end to end, on the seeded demo library.
final class RecipeScalingUITests: XCTestCase {
    @MainActor
    func testChangingTheYieldRewritesTheIngredientAmounts() {
        let app = launchApp(startingOn: "Recipes")

        // The card's identifier carries the slug in both the grid and the
        // gallery, so this does not depend on which view mode a fresh
        // library opens in, nor on where the recipe sorts.
        let smashBurgers = app.buttons.matching(
            NSPredicate(
                format: "identifier ENDSWITH 'crispy-chili-oil-smash-burgers'"
            )
        ).firstMatch
        XCTAssertTrue(smashBurgers.waitForExistence(timeout: 5))
        smashBurgers.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["recipe.detail"]
                .waitForExistence(timeout: 5)
        )

        // As written, the row is the creator's own phrase.
        let asWritten = app.staticTexts[
            "1 lb ground beef — 80/20, in four loose balls"
        ]
        XCTAssertTrue(asWritten.waitForExistence(timeout: 3))

        let yield = app.buttons["recipe.yield"]
        XCTAssertTrue(yield.waitForExistence(timeout: 3))
        for _ in 0..<4 where !yield.isHittable {
            app.swipeUp()
        }
        yield.tap()

        // Four servings to eight, one arrow at a time.
        let increment = app.steppers.firstMatch.buttons["Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 3))
        for _ in 0..<4 {
            increment.tap()
        }
        attachScreenshot(of: app, named: "Servings stepper at 8")
        app.buttons["recipe.servings.done"].tap()

        // The amount is recomputed from the split, and the band says what it
        // was scaled from rather than claiming the recipe yields eight.
        XCTAssertTrue(
            app.staticTexts["2 lb ground beef — 80/20, in four loose balls"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(asWritten.exists)
        XCTAssertTrue(app.staticTexts["Scaled from 4 servings"].exists)

        attachScreenshot(of: app, named: "Recipe scaled to 8 servings")
    }

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

    private func attachScreenshot(
        of app: XCUIApplication,
        named name: String
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
