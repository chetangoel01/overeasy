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

    func testWelcomeTourEndsWithGuestContinue() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Overeasy"]
                .waitForExistence(timeout: 2)
        )
        capture("Welcome tour", in: app)

        let continueButton = element(
            in: app,
            identifier: "welcome.continue"
        )
        XCTAssertTrue(continueButton.waitForExistence(timeout: 2))
        continueButton.tap()
        XCTAssertTrue(
            app.staticTexts["Paste any\nrecipe link"]
                .waitForExistence(timeout: 2)
        )
        continueButton.tap()
        XCTAssertTrue(
            element(in: app, identifier: "welcome.share-trial")
                .waitForExistence(timeout: 2)
        )
        continueButton.tap()

        XCTAssertTrue(
            app.buttons["Sign in with Apple"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Create a free account"].exists)
        XCTAssertTrue(
            app.staticTexts["Guests can save up to 10 recipes."].exists
        )

        app.buttons["Continue as a guest"].tap()

        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.buttons["Continue as a guest"].exists)
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
