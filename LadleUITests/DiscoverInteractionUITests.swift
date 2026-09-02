import XCTest

final class DiscoverInteractionUITests: XCTestCase {
    @MainActor
    func testDiscoverRecipeSupportsTapAndLongPress() throws {
        let app = launchApp()

        app.tabBars.buttons["Discover"].tap()
        let title = app.staticTexts["Crispy Chili Oil Smash Burgers"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        attachScreenshot(of: app, named: "Discover loaded results")

        // A row's identifier is `discover.<original URL>`, so match the
        // scheme too: plain `discover.` also catches `discover.sort`, which
        // now precedes the rows in the hierarchy on a Discover-first launch.
        // The scheme is also what keeps this on an "All recipes" row rather
        // than a shelf card, whose identifier is
        // `discover.card.<shelf>.<original URL>`.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'discover.http'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 2))

        // 15% across, 50% down is over the row's artwork: inside the button
        // that opens the recipe, and the furthest the row gets from the Save
        // control on its trailing edge, so the long press cannot be read as
        // a press on Save.
        let pressPoint = row.coordinate(
            withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)
        )
        // A row exists long before it is on screen, so `waitForExistence`
        // above proves nothing about where the press will land. On #65 the
        // first row's frame was {{16, 829.7}, {370, 111.3}} on this
        // 402x874-point phone, so 50% down computed y = 885.3 — eleven points
        // past the bottom edge — and that run ended on a recipe detail rather
        // than on the menu. Scroll the row up until the point this test
        // presses is genuinely on screen.
        var scrolls = 0
        while scrolls < 4,
              !row.isHittable || !app.frame.contains(pressPoint.screenPoint) {
            app.swipeUp(velocity: .slow)
            scrolls += 1
        }
        XCTAssertTrue(
            row.isHittable && app.frame.contains(pressPoint.screenPoint),
            """
            The first All recipes row has to be on screen before it is
            pressed. Row \(row.frame) in an app of \(app.frame).
            """
        )
        pressPoint.press(forDuration: 1)
        XCTAssertTrue(app.buttons["View Recipe"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Save Recipe"].exists)

        // The pushed detail is the read-only Discover one: it carries the
        // account control but no favourite or options menu. This asserted a
        // "Discover preview" badge until 46dd921 deliberately removed it and
        // left the assertion behind.
        app.buttons["View Recipe"].tap()
        let account = app.buttons["Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Recipe options"].exists)
    }

    /// The header is the reason `-account-state` exists: until it did, no UI
    /// test could reach a signed-in screen at all. There is no `AuthClient`
    /// under `-ui-testing`, so the profile comes from the launch arguments.
    @MainActor
    func testSettingsHeaderShowsTheSignedInCook() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-account-state",
            "signedInWithGoogle",
            "-account-display-name",
            "Priya Raman",
        ]
        app.launch()

        let settings = app.buttons["Settings and account"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 2))
        // The name is a button — tapping it edits in place — so it is not a
        // static text and has to be found by identifier.
        let name = app.descendants(matching: .any)["account.profile.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        XCTAssertEqual(name.label, "Priya Raman")
        XCTAssertTrue(app.staticTexts["Signed in with Google"].exists)
        XCTAssertFalse(
            app.buttons["account.profile.sign-in"].exists,
            "A signed-in cook is not offered a sign-in button"
        )
        attachScreenshot(of: app, named: "Settings profile header")
    }

    @MainActor
    func testSettingsAccentAndRecipeViewPreferencesAreReachable() throws {
        let app = launchApp(startingOn: "Recipes")

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
        let app = launchApp(startingOn: "Recipes")

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

    /// Its own launch, deliberately. Chaining this onto the test above saves a
    /// launch but changes what it measures: with the slow import still in
    /// flight, a second Add recipe tap does not present the sheet at all.
    @MainActor
    func testFailedImportRecoveryActionsShareLabelOrigin() throws {
        let app = launchApp(startingOn: "Recipes")

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
        let app = launchApp(startingOn: "Recipes")

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

    /// A launch lands on Discover, so a test about another tab has to ask
    /// for it rather than assume the first screen is its own.
    @MainActor
    private func launchApp(startingOn tab: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()
        if let tab {
            let button = app.tabBars.buttons[tab]
            XCTAssertTrue(
                button.waitForExistence(timeout: 5),
                "Expected the \(tab) tab after launch"
            )
            button.tap()
        }
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

        // Watch shares one control row: no account button there, and the
        // playback controls sit beside the feed picker rather than per page.
        // Before the swipe, because Save belongs to the page in view.
        XCTAssertFalse(app.buttons["Account"].exists)
        XCTAssertTrue(app.buttons["Save"].firstMatch.isHittable)

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
        attachScreenshot(of: app, named: "Watch full-screen feed")

        // Switching feeds replaces the pages: saved recipes open, they do not
        // save. Last, because it swaps what the feed is showing.
        let feed = app.segmentedControls["watch.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 2))
        feed.buttons["My Recipes"].tap()
        XCTAssertTrue(
            app.buttons["Save"].firstMatch.waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["Open recipe"].firstMatch.waitForExistence(timeout: 3)
        )

        feed.buttons["Discover"].tap()
        XCTAssertTrue(
            app.buttons["Save"].firstMatch.waitForExistence(timeout: 3)
        )
    }
}
