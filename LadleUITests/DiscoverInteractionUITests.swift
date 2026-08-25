import XCTest

final class DiscoverInteractionUITests: XCTestCase {
    @MainActor
    func testDiscoverRecipeSupportsTapAndLongPress() throws {
        let app = launchApp()

        app.tabBars.buttons["Discover"].tap()
        let title = app.staticTexts["Crispy Chili Oil Smash Burgers"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))

        title.press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["View Recipe"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Save Recipe"].exists)

        app.buttons["View Recipe"].tap()
        XCTAssertTrue(app.staticTexts["Discover preview"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Account"].exists)
    }

    @MainActor
    func testWatchFeedPagesOneRecipePerViewport() throws {
        let app = launchApp()

        app.tabBars.buttons["Watch"].tap()

        let feed = app.scrollViews.firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 3))

        let pageControls = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'watch.'")
        )
        let firstPageControl = pageControls.element(boundBy: 0)
        XCTAssertTrue(firstPageControl.waitForExistence(timeout: 2))
        XCTAssertTrue(firstPageControl.isHittable)
        XCTAssertTrue(app.buttons["Account"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Start cooking"].firstMatch.isHittable)

        feed.swipeUp()

        let secondPageControl = pageControls.element(boundBy: 1)
        let secondPageIsVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: secondPageControl
        )
        wait(for: [secondPageIsVisible], timeout: 3)
        XCTAssertFalse(firstPageControl.isHittable)
        XCTAssertNotEqual(
            secondPageControl.identifier,
            firstPageControl.identifier
        )

        attachScreenshot(of: app, named: "Watch full-screen feed")
    }

    @MainActor
    func testSettingsAccentAndRecipeViewPreferencesAreReachable() throws {
        let app = launchApp()

        let settings = app.buttons["Settings and account"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        let blue = app.buttons["Blue"]
        XCTAssertTrue(blue.waitForExistence(timeout: 2))
        blue.tap()
        XCTAssertEqual(blue.value as? String, "Selected")
        attachScreenshot(of: app, named: "Settings accent colors")

        app.buttons["Close"].tap()
        let viewMenu = app.buttons["Recipe view"]
        XCTAssertTrue(viewMenu.waitForExistence(timeout: 2))
        attachScreenshot(of: app, named: "Recipe grid view")
        viewMenu.tap()
        app.buttons["List"].tap()

        let listRecipe = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.list.'")
        ).firstMatch
        XCTAssertTrue(listRecipe.waitForExistence(timeout: 2))
        attachScreenshot(of: app, named: "Recipe list view")
    }

    @MainActor
    func testRecipeProcessingSheetCanBeDismissedWhileImportContinues() throws {
        let app = launchApp()

        app.buttons["Add recipe"].tap()
        let link = app.textFields["Recipe link"]
        XCTAssertTrue(link.waitForExistence(timeout: 2))
        link.tap()
        link.typeText(
            "https://www.tiktok.com/@mia_cooks/video/slow-1234567890"
        )
        app.buttons["Import from link"].tap()

        let keepBrowsing = app.buttons["Keep browsing"]
        XCTAssertTrue(keepBrowsing.waitForExistence(timeout: 2))
        keepBrowsing.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["library.all-recipes"]
                .waitForExistence(timeout: 2)
        )
    }

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func attachScreenshot(
        of app: XCUIApplication,
        named name: String
    ) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
