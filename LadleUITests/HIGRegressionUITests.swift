import XCTest

@MainActor
final class HIGRegressionUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testServingsResetIsReachableAtLargestTextSize() {
        let app = launch(largeText: true)
        openRecipe(in: app)
        let yield = app.buttons["recipe.yield"]
        reveal(yield, in: app)
        yield.tap()
        let increment = app.steppers.firstMatch.buttons["Increment"]
        XCTAssertTrue(increment.waitForExistence(timeout: 3))
        increment.tap()
        let reset = app.buttons["recipe.servings.reset"]
        reveal(reset, in: app)
        XCTAssertTrue(reset.isHittable)
        XCTAssertLessThanOrEqual(reset.frame.maxY, app.frame.maxY)
        capture(app, "HIG servings AX5")
        reset.tap()
        XCTAssertFalse(reset.exists)
        app.buttons["recipe.servings.done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.detail"].exists)
    }

    func testEditorCancelOffersKeepEditingAndDiscard() {
        let app = launch()
        openEditor(in: app)
        let title = app.textFields["Recipe title"]
        title.tap()
        title.typeText(" changed")
        app.buttons["Cancel"].tap()
        let keep = app.buttons["Keep Editing"]
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        capture(app, "HIG discard confirmation")
        keep.tap()
        XCTAssertTrue((title.value as? String)?.contains("changed") == true)
        app.buttons["Cancel"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.detail"].waitForExistence(timeout: 3))
        app.buttons["Recipe options"].tap()
        app.buttons["Edit recipe"].tap()
        XCTAssertFalse((app.textFields["Recipe title"].value as? String)?.contains("changed") == true)
    }

    func testEditorSectionStartsAtItsHeading() {
        let app = launch()
        openEditor(in: app)
        app.buttons["Ingredients section"].tap()
        app.swipeUp()
        app.swipeUp()
        app.buttons["Method section"].tap()
        XCTAssertTrue(app.staticTexts["Method"].isHittable)
        capture(app, "HIG editor section reset")
    }

    func testProfileSignInUsesBackWithinOneSheet() {
        let app = launch(guest: true)
        app.buttons["Profile"].tap()
        app.buttons["account.profile.sign-in"].tap()
        let bar = app.navigationBars["Sign in"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        XCTAssertFalse(app.navigationBars["Profile"].buttons["Close"].isHittable)
        XCTAssertTrue(bar.buttons["Profile"].exists)
        capture(app, "HIG profile sign in")
        bar.buttons["Profile"].tap()
        XCTAssertTrue(app.navigationBars["Profile"].exists)
    }

    func testEditorSwipeOffersDiscardAndKeepsTheDraft() {
        let app = launch()
        openEditor(in: app)
        let title = app.textFields["Recipe title"]
        title.tap()
        title.typeText(" draft")
        let bar = app.navigationBars["Edit recipe"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue((title.value as? String)?.contains("draft") == true)
        app.buttons["Cancel"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.detail"].waitForExistence(timeout: 3))
    }

    func testManualEntryOnlyConfirmsWhenThereAreChanges() {
        let app = launch()
        app.buttons["Add recipe"].tap()
        reveal(app.buttons["Create manually"], in: app)
        app.buttons["Create manually"].tap()
        app.buttons["Close"].tap()
        XCTAssertFalse(app.buttons["Discard Changes"].exists)
        app.buttons["Add recipe"].tap()
        reveal(app.buttons["Create manually"], in: app)
        app.buttons["Create manually"].tap()
        let title = app.textFields["Recipe title"]
        title.tap()
        title.typeText("Tomato soup")
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
        app.buttons["Keep Editing"].tap()
        XCTAssertEqual(title.value as? String, "Tomato soup")
        app.buttons["Close"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["Add recipe"].waitForExistence(timeout: 3))
    }

    func testRecoveryUsesBackAndProtectsAllThreeDrafts() {
        let app = launch()
        app.buttons["Add recipe"].tap()
        let link = app.textFields["Recipe link"]
        link.tap()
        link.typeText("https://www.tiktok.com/@ladle/video/parser-failed")
        reveal(app.buttons["Import from link"], in: app)
        app.buttons["Import from link"].tap()
        XCTAssertTrue(app.staticTexts["import.recovery.correctionNotes.label"].waitForExistence(timeout: 8))
        for (mode, field) in [("correctionNotes", "Correction notes"), ("pastedDetails", "Pasted recipe details"), ("manual", "Recipe details")] {
            let action = app.staticTexts["import.recovery.\(mode).label"]
            reveal(action, in: app)
            action.tap()
            let back = app.buttons["Back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Close"].isHittable)
            let text = app.textViews[field]
            text.tap()
            text.typeText("Use two tomatoes")
            if mode == "correctionNotes" {
                app.navigationBars["Add correction notes"]
                    .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                    .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
                XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
                app.buttons["Keep Editing"].tap()
                XCTAssertEqual(text.value as? String, "Use two tomatoes")
            }
            back.tap()
            XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
            app.buttons["Keep Editing"].tap()
            XCTAssertEqual(text.value as? String, "Use two tomatoes")
            back.tap()
            app.buttons["Discard Changes"].tap()
            XCTAssertTrue(action.waitForExistence(timeout: 3))
        }
        capture(app, "HIG recovery returned to import")
    }

    func testHealthExportReturnsToNutritionWithinTheSheet() {
        let app = launch()
        openRecipe(in: app)
        app.buttons["Recipe options"].tap()
        app.buttons["View nutrition"].tap()
        let export = app.buttons["Export to Apple Health"]
        reveal(export, in: app)
        export.tap()
        let bar = app.navigationBars["Apple Health"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        XCTAssertTrue(bar.buttons["Nutrition"].exists)
        capture(app, "HIG health export Back")
        bar.buttons["Nutrition"].tap()
        XCTAssertTrue(app.navigationBars["Nutrition"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.detail"].exists)
    }

    func testWatchActionsStackAtLargestTextSize() {
        let app = launch(largeText: true)
        app.tabBars.buttons["Watch"].tap()
        let feed = app.segmentedControls["watch.feed"]
        XCTAssertTrue(feed.waitForExistence(timeout: 5))
        let save = app.buttons["Save"].firstMatch
        let view = app.buttons["View recipe"].firstMatch
        reveal(view, in: app)
        XCTAssertTrue(save.exists)
        XCTAssertTrue(view.isHittable)
        XCTAssertGreaterThanOrEqual(view.frame.minY, save.frame.maxY)
        XCTAssertEqual(view.frame.width, save.frame.width, accuracy: 1)
        capture(app, "HIG Watch discover AX5")
        feed.buttons["My Recipes"].tap()
        let start = app.buttons["Start cooking"].firstMatch
        reveal(start, in: app)
        let open = app.buttons["Open recipe"].firstMatch
        XCTAssertTrue(start.isHittable)
        XCTAssertGreaterThanOrEqual(start.frame.minY, open.frame.maxY)
        capture(app, "HIG Watch recipes AX5")
    }

    func testCustomSignInButtonsFitAtLargestTextSize() {
        let app = launch(largeText: true, guest: true)
        app.buttons["Profile"].tap()
        app.buttons["account.profile.sign-in"].tap()
        let apple = app.buttons["account.apple-sign-in"]
        let google = app.buttons["account.google-sign-in"]
        reveal(google, in: app)
        XCTAssertTrue(apple.isHittable)
        XCTAssertTrue(google.isHittable)
        XCTAssertGreaterThanOrEqual(apple.frame.height, 44)
        XCTAssertEqual(apple.frame.height, google.frame.height, accuracy: 1)
        XCTAssertLessThanOrEqual(google.frame.maxX, app.frame.maxX)
        capture(app, "HIG custom sign in AX5")
    }

    func testWelcomeProviderButtonsFitAtLargestTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-reset-onboarding", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let apple = app.buttons["welcome.apple-sign-in"]
        let google = app.buttons["welcome.google-sign-in"]
        XCTAssertTrue(apple.waitForExistence(timeout: 5))
        reveal(google, in: app)
        XCTAssertTrue(apple.isHittable)
        XCTAssertTrue(google.isHittable)
        XCTAssertGreaterThanOrEqual(apple.frame.minX, 0)
        XCTAssertLessThanOrEqual(google.frame.maxX, app.frame.maxX)
        capture(app, "HIG welcome actions AX5")
        let guest = app.buttons["Try as a guest"]
        reveal(guest, in: app)
        guest.tap()
        XCTAssertTrue(app.buttons["diet-step.continue"].waitForExistence(timeout: 5))
    }

    private func launch(largeText: Bool = false, guest: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-onboarding-complete", "-reset-library-preferences"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if guest { app.launchArguments += ["-account-state", "guest"] }
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Recipes"].tap()
        return app
    }

    private func openRecipe(in app: XCUIApplication) {
        let card = app.buttons.matching(NSPredicate(format: "identifier ENDSWITH 'crispy-chili-oil-smash-burgers'")).firstMatch
        for _ in 0..<12 where !card.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        for _ in 0..<12 where card.frame.minY > app.frame.height * 0.55 { app.swipeUp(velocity: .slow) }
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.2)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.detail"].waitForExistence(timeout: 5))
    }

    private func openEditor(in app: XCUIApplication) {
        openRecipe(in: app)
        app.buttons["Recipe options"].tap()
        app.buttons["Edit recipe"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["recipe.editor"].waitForExistence(timeout: 3))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable { app.swipeUp() }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
