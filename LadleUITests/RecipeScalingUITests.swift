import XCTest

/// Scaling a recipe from the band's inline stepper, end to end, on the seeded
/// demo library.
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

        // At the count the recipe claims, the row is the amount as stored.
        let asWritten = app.staticTexts[
            "1 lb ground beef — 80/20, in four loose balls"
        ]
        XCTAssertTrue(asWritten.waitForExistence(timeout: 3))

        // The header is a thumbnail, not a hero, so the facts a cook opens a
        // recipe for are whole on the first screen. Frames, not `isHittable`:
        // under the 322-point hero the nutrition card's hit point was already
        // reachable while most of the card sat beneath the tab bar.
        let servings = app.descendants(matching: .any)["recipe.servings"]
        XCTAssertTrue(servings.waitForExistence(timeout: 3))
        let nutrition = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Nutrition per serving'")
        ).firstMatch
        XCTAssertLessThanOrEqual(
            nutrition.frame.maxY,
            app.tabBars.firstMatch.frame.minY,
            "Time, servings and nutrition open without scrolling"
        )

        // Four servings to eight, on the band itself: no sheet, no Done. The
        // stepper is one adjustable element to VoiceOver, so the test presses
        // where a finger does — the plus is the trailing end of the control.
        let plus = servings.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        )
        for _ in 0..<4 {
            plus.tap()
        }
        XCTAssertTrue(
            app.staticTexts["2 lb ground beef — 80/20, in four loose balls"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(asWritten.exists)

        // Reset is the way back, and it leaves with the scaling it undoes.
        let reset = app.buttons["recipe.servings.reset"]
        reset.tap()
        XCTAssertTrue(asWritten.waitForExistence(timeout: 3))
        XCTAssertFalse(reset.exists)
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
}
