import XCTest

@MainActor
final class LadleLaunchTests: XCTestCase {
    func testLaunchShowsRecipeLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-onboarding-complete"]
        app.launch()

        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 2),
            "The recipe library root should be visible after launch."
        )
    }

    func testWelcomeLetsUserContinueAsGuest() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Recipes, rescued from the scroll."]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Sign in with Apple"].exists)
        XCTAssertTrue(app.buttons["Create a free account"].exists)
        XCTAssertTrue(app.staticTexts["Guests can save up to 10 recipes."].exists)
        capture("Welcome", in: app)

        app.buttons["Continue as a guest"].tap()

        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            app.staticTexts["Recipes, rescued from the scroll."].exists
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
