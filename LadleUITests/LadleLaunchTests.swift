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

    func testAccountSheetPresentsScannableTransparencyDetails() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-onboarding-complete"]
        app.launch()

        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 2)
        )
        app.buttons["Account"].tap()

        XCTAssertTrue(
            element(in: app, identifier: "account.privacy")
                .waitForExistence(timeout: 2)
        )
        capture("Account — summary", in: app)
        element(in: app, identifier: "account.privacy").tap()

        XCTAssertTrue(
            app.staticTexts["What Overeasy stores"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            staticText(
                in: app,
                label:
                "The links you import and the recipes extracted from them — ingredients, steps, timers, and estimated nutrition — synced to your account."
            ).exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "No ads, no analytics SDKs, no selling or sharing data with third parties."
            ].exists
        )
        capture("Account — privacy detail", in: app)
        app.navigationBars.buttons.firstMatch.tap()

        let signOut = element(in: app, identifier: "account.sign-out")
        XCTAssertTrue(signOut.waitForExistence(timeout: 2))
        for _ in 0..<3 where !signOut.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(signOut.isHittable)

        signOut.tap()
        XCTAssertTrue(
            app.staticTexts["Sign out of Overeasy?"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Recipes are removed from this device but stay in your synced library."
            ].exists
        )
        capture("Account — sign-out confirmation", in: app)
    }

    private func element(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func staticText(
        in app: XCUIApplication,
        label: String
    ) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "label == %@", label))
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
