import XCTest

final class DiscoverInteractionUITests: XCTestCase {
    @MainActor
    func testDiscoverRecipeSupportsTapAndLongPress() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()

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
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()

        app.tabBars.buttons["Watch"].tap()

        let feed = app.scrollViews.firstMatch
        XCTAssertTrue(feed.waitForExistence(timeout: 3))

        let pageControls = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'watch.'")
        )
        let firstPageControl = pageControls.element(boundBy: 0)
        XCTAssertTrue(firstPageControl.waitForExistence(timeout: 3))
        XCTAssertTrue(firstPageControl.isHittable)
        XCTAssertTrue(app.buttons["Account"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Start cooking"].firstMatch.isHittable)

        app.swipeUp()

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

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Watch full-screen feed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    func testWatchDefaultsToInlinePlayerWithPlaybackControls() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()

        app.tabBars.buttons["Watch"].tap()

        let player = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'watch.player.'")
        ).firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        XCTAssertEqual(player.frame.minX, app.frame.minX, accuracy: 1)
        XCTAssertEqual(player.frame.minY, app.frame.minY, accuracy: 1)
        XCTAssertEqual(player.frame.width, app.frame.width, accuracy: 1)
        XCTAssertEqual(player.frame.height, app.frame.height, accuracy: 1)
        XCTAssertFalse(app.buttons["Close video"].exists)

        let pause = app.buttons["Pause video"].firstMatch
        let mute = app.buttons["Mute video"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 2))
        XCTAssertTrue(mute.isHittable)
        let firstPageIdentifier = pause.identifier

        pause.tap()
        let resume = app.buttons["Resume video"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 2))

        mute.tap()
        XCTAssertTrue(
            app.buttons["Unmute video"].firstMatch.waitForExistence(timeout: 2)
        )

        let loadingIndicator = app.descendants(matching: .any)[
            "watch.player.loading"
        ]
        if loadingIndicator.waitForExistence(timeout: 1) {
            XCTAssertTrue(
                loadingIndicator.waitForNonExistence(timeout: 12),
                "The inline player should finish its main navigation."
            )
        }

        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertNotEqual(safari.state, .runningForeground)
        XCTAssertEqual(app.state, .runningForeground)

        app.swipeUp()

        let nextPageControl = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'watch.' AND identifier != %@",
                firstPageIdentifier
            )
        ).firstMatch
        XCTAssertTrue(nextPageControl.waitForExistence(timeout: 3))
        XCTAssertTrue(nextPageControl.isHittable)
        let previousPageControl = app.buttons.matching(
            NSPredicate(format: "identifier == %@", firstPageIdentifier)
        ).firstMatch
        XCTAssertFalse(previousPageControl.isHittable)
    }
}
