import XCTest

final class StateScenarioUITests: XCTestCase {
    @MainActor
    func testEmptyLibraryScenario() {
        let app = launchApp(scenario: "empty")

        XCTAssertTrue(app.staticTexts["No recipes yet"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "Scenario - empty library")
    }

    @MainActor
    func testOfflineContentScenarioPreservesRecipes() {
        let app = launchApp(scenario: "offline-content")

        XCTAssertTrue(
            app.descendants(matching: .any)["sync.status"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["You're offline"].exists)
        XCTAssertTrue(app.staticTexts["Crispy Chili Oil Smash Burgers"].exists)
        attachScreenshot(of: app, named: "Scenario - offline with recipes")
    }

    @MainActor
    func testOfflineEmptyScenarioExplainsBothStates() {
        let app = launchApp(scenario: "offline-empty")

        XCTAssertTrue(app.staticTexts["You're offline"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No recipes yet"].exists)
        attachScreenshot(of: app, named: "Scenario - offline empty")
    }

    @MainActor
    func testInitialStoreFailureScenario() {
        let app = launchApp(scenario: "store-failure")

        XCTAssertTrue(
            app.descendants(matching: .any)["bootstrap.failure"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Recipes couldn’t be opened"].exists)
        XCTAssertTrue(app.buttons["Retry"].exists)
        attachScreenshot(of: app, named: "Scenario - store failure")
    }

    @MainActor
    func testDiscoverEmptyScenario() {
        let app = launchApp(scenario: "discover-empty")
        app.tabBars.buttons["Discover"].tap()

        XCTAssertTrue(app.staticTexts["Nothing to discover yet"].waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "Scenario - Discover empty")
    }

    @MainActor
    func testDiscoverRateLimitedScenario() {
        let app = launchApp(scenario: "discover-rate-limited")
        app.tabBars.buttons["Discover"].tap()

        XCTAssertTrue(
            app.staticTexts["Too many requests"]
                .waitForExistence(timeout: 3)
        )
        attachScreenshot(of: app, named: "Scenario - Discover rate limited")
    }

    @MainActor
    func testImportQuotaScenario() {
        let app = launchApp(scenario: "import-quota")
        submitImport(in: app)

        XCTAssertTrue(app.staticTexts["Limit reached"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Retry after capacity resets"].exists)
        attachScreenshot(of: app, named: "Scenario - import quota")
    }

    @MainActor
    func testImportRateLimitedScenario() {
        let app = launchApp(scenario: "import-rate-limited")
        submitImport(in: app)

        XCTAssertTrue(app.staticTexts["Too many requests"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH 'Retry after'")
            ).firstMatch.exists
        )
        attachScreenshot(of: app, named: "Scenario - import rate limited")
    }

    @MainActor
    func testAuthenticationExpiredScenario() {
        let app = launchApp(scenario: "authentication-expired")

        XCTAssertTrue(app.staticTexts["Sign in again"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["sync.status"].exists)
        attachScreenshot(of: app, named: "Scenario - authentication expired")
    }

    @MainActor
    func testLargeLibraryScenario() {
        let app = launchApp(scenario: "large-library")

        XCTAssertTrue(app.staticTexts["80 recipes"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Weeknight Recipe 80"].exists)
        attachScreenshot(of: app, named: "Scenario - large library")
    }

    @MainActor
    func testLargeLibraryAtXXXLargeUsesOneReadableColumn() {
        let app = launchApp(
            scenario: "large-library",
            contentSizeCategory: "UICTContentSizeCategoryXXXL"
        )
        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.grid.'")
        )
        let first = cards.element(boundBy: 0)
        let second = cards.element(boundBy: 1)

        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertEqual(first.frame.minX, second.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        attachScreenshot(of: app, named: "Scenario - large library XXX Large")
    }

    @MainActor
    func testWelcomeAtAccessibilitySizeRemainsReachable() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-reset-onboarding",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Overeasy"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Try as a guest"].exists)
        attachScreenshot(of: app, named: "Welcome - accessibility XXX Large")
    }

    @MainActor
    func testPrimaryJourneyCapturesInboxDetailAndCooking() {
        let app = launchApp(scenario: "standard")

        app.tabBars.buttons["Inbox"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.import-inbox.root"]
                .waitForExistence(timeout: 3)
        )
        attachScreenshot(of: app, named: "Inbox - active states")

        app.tabBars.buttons["Recipes"].tap()
        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.grid.'")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 3))
        recipe.tap()
        XCTAssertTrue(
            app.buttons["Recipe options"]
                .waitForExistence(timeout: 3)
        )
        attachScreenshot(of: app, named: "Recipe detail")

        let startCooking = app.buttons["Start Cooking"]
        for _ in 0..<4 where !startCooking.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(startCooking.waitForExistence(timeout: 3))
        startCooking.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["cooking.full-recipe"]
                .waitForExistence(timeout: 3)
        )
        attachScreenshot(of: app, named: "Cooking - full recipe")

        app.buttons["Focus mode"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["cooking.focus-mode"]
                .waitForExistence(timeout: 3)
        )
        attachScreenshot(of: app, named: "Cooking - focus mode")
    }

    @MainActor
    private func launchApp(
        scenario: String,
        contentSizeCategory: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
            "-demo-scenario",
            scenario,
        ]
        if let contentSizeCategory {
            app.launchArguments += [
                "-UIPreferredContentSizeCategoryName",
                contentSizeCategory,
            ]
        }
        app.launch()
        return app
    }

    @MainActor
    private func submitImport(in app: XCUIApplication) {
        app.buttons["Add recipe"].tap()
        let link = app.textFields["Recipe link"]
        XCTAssertTrue(link.waitForExistence(timeout: 2))
        link.tap()
        link.typeText("https://youtu.be/deterministic-state")
        app.buttons["Import from link"].tap()
    }

    @MainActor
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
