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

    func testWelcomeGetsNewUsersToTheWalkthrough() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding"]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Recipes, rescued from the scroll."]
                .waitForExistence(timeout: 2)
        )
        let welcome = element(in: app, identifier: "welcome.full-screen")
        XCTAssertTrue(welcome.exists)
        XCTAssertLessThanOrEqual(welcome.frame.minY, app.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(welcome.frame.maxY, app.frame.maxY - 1)
        XCTAssertFalse(element(in: app, identifier: "library.root").exists)
        XCTAssertTrue(
            element(in: app, identifier: "welcome.brand-mark").exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "Turn TikTok, Instagram, and YouTube links into clear recipes made for cooking."
            ].exists
        )
        XCTAssertTrue(
            app.staticTexts["Start your recipe box"].exists
        )
        XCTAssertTrue(
            app.buttons["Continue with Apple"].exists
        )
        XCTAssertTrue(
            app.buttons["Sign in with Google"].exists
        )
        XCTAssertTrue(
            app.buttons["Try as a guest"].exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "Guests can save up to 10 recipes. Sign in later without losing them."
            ].exists
        )
        XCTAssertFalse(app.buttons["Skip the tour"].exists)
        XCTAssertFalse(app.buttons["Add Recipe"].isHittable)
        capture("Welcome", in: app)

        app.buttons["Try as a guest"].tap()

        XCTAssertTrue(
            element(in: app, identifier: "onboarding.root")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.buttons["Try as a guest"].exists)
        XCTAssertFalse(element(in: app, identifier: "library.root").exists)
    }

    func testFirstAccountWalkthroughTeachesTheCoreLoop() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding"]
        app.launch()
        app.buttons["Try as a guest"].tap()

        XCTAssertTrue(
            app.staticTexts["Share from any recipe video"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Add to Overeasy"].exists)
        capture("Walkthrough — share", in: app)

        app.buttons["Next"].tap()
        XCTAssertTrue(
            app.staticTexts["Check what Overeasy rescued"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"].exists
        )
        capture("Walkthrough — review", in: app)

        app.buttons["Next"].tap()
        XCTAssertTrue(
            app.staticTexts["Cook one clear step at a time"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Simmer the orzo"].exists)
        capture("Walkthrough — cook", in: app)

        app.buttons["Start saving recipes"].tap()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            element(in: app, identifier: "onboarding.root").exists
        )
    }

    func testWelcomeProviderButtonsShareVisualRhythm() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding"]
        app.launch()

        let apple = app.buttons["Continue with Apple"]
        let google = app.buttons["Sign in with Google"]
        XCTAssertTrue(apple.waitForExistence(timeout: 2))
        XCTAssertTrue(google.exists)
        XCTAssertTrue(app.staticTexts["Start your recipe box"].exists)
        XCTAssertFalse(
            app.staticTexts["Paste a link or share from the scroll."].exists
        )
        XCTAssertEqual(apple.frame.minX, google.frame.minX, accuracy: 0.5)
        XCTAssertEqual(apple.frame.maxX, google.frame.maxX, accuracy: 0.5)
        XCTAssertEqual(apple.frame.height, google.frame.height, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(google.frame.height, 51.5)
    }

    func testEmptyLibraryGuidesTheFirstRecipe() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-empty-library",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Save your first recipe"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Paste a TikTok, Instagram, or YouTube link. Overeasy turns it into ingredients and steps you can cook from."
            ].exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "While scrolling, you can also use Share and choose Add to Overeasy."
            ].exists
        )

        let homeAddRecipe = app.buttons["Add your first recipe"]
        XCTAssertTrue(homeAddRecipe.exists)
        XCTAssertGreaterThanOrEqual(homeAddRecipe.frame.height, 43.5)
        capture("Empty library", in: app)

        app.buttons["All 0"].tap()
        XCTAssertTrue(
            app.staticTexts["No recipes yet"]
                .waitForExistence(timeout: 2)
        )
        let addFirstRecipe = app.buttons["Add your first recipe"]
        XCTAssertTrue(addFirstRecipe.exists)
        XCTAssertGreaterThanOrEqual(addFirstRecipe.frame.height, 43.5)

        addFirstRecipe.tap()
        XCTAssertTrue(
            app.staticTexts["Add a recipe"]
                .waitForExistence(timeout: 2)
        )
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
                "No ads, no cross-app tracking, and no sale of personal data."
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
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
            .tap()

        let deleteAccount = element(
            in: app,
            identifier: "account.delete"
        )
        for _ in 0..<3 where !deleteAccount.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deleteAccount.isHittable)
        deleteAccount.tap()
        XCTAssertTrue(
            app.staticTexts["Delete your Overeasy account?"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts[
                "Your synced recipes and account data will be permanently deleted. This can’t be undone."
            ].exists
        )
        capture("Account — deletion confirmation", in: app)
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
