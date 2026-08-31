import XCTest

final class DiscoverInteractionUITests: XCTestCase {
    @MainActor
    func testDiscoverRecipeSupportsTapAndLongPress() throws {
        let app = launchApp()

        app.tabBars.buttons["Discover"].tap()
        let title = app.staticTexts["Crispy Chili Oil Smash Burgers"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "Discover loaded results")

        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'discover.'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2))
        row.coordinate(
            withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)
        ).press(forDuration: 1)
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
        XCTAssertTrue(firstPageControl.waitForExistence(timeout: 3))
        XCTAssertTrue(firstPageControl.isHittable)
        // Watch shares one control row: no account button there, and the
        // playback controls sit beside the feed picker rather than per page.
        XCTAssertFalse(app.buttons["Account"].exists)
        XCTAssertTrue(app.buttons["Pause video"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Mute video"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["Save"].firstMatch.isHittable)

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

        attachScreenshot(of: app, named: "Watch full-screen feed")
    }

    @MainActor
    func testWatchFeedSelectorSwitchesBetweenSavedAndDiscover() throws {
        let app = launchApp()

        app.tabBars.buttons["Watch"].tap()
        XCTAssertTrue(
            app.buttons["Save"].firstMatch.waitForExistence(timeout: 3)
        )

        let feed = app.segmentedControls["watch.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 2))
        let myRecipes = feed.buttons["My Recipes"]
        let discover = feed.buttons["Discover"]

        myRecipes.tap()
        XCTAssertTrue(
            app.buttons["Save"].firstMatch.waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["Open recipe"].firstMatch.waitForExistence(timeout: 3)
        )

        discover.tap()
        XCTAssertTrue(
            app.buttons["Save"].firstMatch.waitForExistence(timeout: 3)
        )
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

        let cards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.grid.'")
        )
        let firstCard = cards.element(boundBy: 0)
        let secondCard = cards.element(boundBy: 1)
        let thirdCard = cards.element(boundBy: 2)
        let fourthCard = cards.element(boundBy: 3)
        XCTAssertTrue(firstCard.waitForExistence(timeout: 2))
        XCTAssertTrue(fourthCard.exists)
        XCTAssertEqual(firstCard.frame.minY, secondCard.frame.minY, accuracy: 1)
        XCTAssertEqual(
            firstCard.frame.height,
            secondCard.frame.height,
            accuracy: 1
        )
        XCTAssertEqual(thirdCard.frame.minY, fourthCard.frame.minY, accuracy: 1)
        XCTAssertEqual(
            thirdCard.frame.height,
            fourthCard.frame.height,
            accuracy: 1
        )

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

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Cancel Import"].isHittable)
        close.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["library.all-recipes"]
                .waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testFailedImportRecoveryActionsShareLabelOrigin() throws {
        let app = launchApp()

        app.buttons["Add recipe"].tap()
        let link = app.textFields["Recipe link"]
        XCTAssertTrue(link.waitForExistence(timeout: 2))
        link.tap()
        link.typeText(
            "https://www.tiktok.com/@ladle/video/parser-failed"
        )
        app.buttons["Import from link"].tap()

        let labels = [
            app.staticTexts["import.recovery.correctionNotes.label"],
            app.staticTexts["import.recovery.pastedDetails.label"],
            app.staticTexts["import.recovery.manual.label"],
        ]
        XCTAssertTrue(labels[0].waitForExistence(timeout: 3))
        XCTAssertTrue(labels[1].exists)
        XCTAssertTrue(labels[2].exists)
        attachScreenshot(of: app, named: "Failed import recovery alignment")

        let expectedOrigin = labels[0].frame.minX
        for label in labels.dropFirst() {
            XCTAssertEqual(
                label.frame.minX,
                expectedOrigin,
                accuracy: 1,
                "Recovery labels should share one leading edge"
            )
        }
    }

    @MainActor
    func testRecipeOptionsExposeTheDeleteAction() throws {
        let app = launchApp()

        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.grid.'")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 3))
        recipe.tap()

        let options = app.buttons["Recipe options"]
        XCTAssertTrue(options.waitForExistence(timeout: 2))
        options.tap()
        XCTAssertTrue(
            app.buttons["Delete recipe"].waitForExistence(timeout: 2)
        )
        attachScreenshot(of: app, named: "Recipe options destructive action")
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
        // Playback controls are shared across pages, so page identity comes
        // from the per-page action row rather than from the pause button.
        let firstPageControl = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'watch.'")
        ).firstMatch
        XCTAssertTrue(firstPageControl.waitForExistence(timeout: 2))
        let firstPageIdentifier = firstPageControl.identifier

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
        // The page identifier rides the action row, which settles last
        // after a scroll, so wait for it rather than asserting instantly.
        let nextPageIsVisible = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: nextPageControl
        )
        wait(for: [nextPageIsVisible], timeout: 3)
        let previousPageControl = app.buttons.matching(
            NSPredicate(format: "identifier == %@", firstPageIdentifier)
        ).firstMatch
        XCTAssertFalse(previousPageControl.isHittable)
    }
}
