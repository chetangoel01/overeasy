import XCTest

@MainActor
final class ImportFlowTests: XCTestCase {
    func testAddSheetOffersLinkManualAndShareActions() {
        let app = launchApp()

        app.buttons["Add Recipe"].tap()

        XCTAssertTrue(
            app.staticTexts["Add a recipe"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.textFields["Recipe link"].exists)
        XCTAssertTrue(app.buttons["Import from link"].exists)
        XCTAssertTrue(app.buttons["Create manually"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Tip: sharing a video to Ladle is even faster."
            ].exists
        )

        app.buttons["Create manually"].tap()

        XCTAssertTrue(app.textFields["Recipe title"].exists)
        XCTAssertTrue(app.textViews["Recipe details"].exists)
        XCTAssertTrue(app.buttons["Save manual recipe"].exists)
        capture("Add recipe — manual entry", in: app)
    }

    func testSlowImportCanContinueAsAParsingCard() {
        let app = launchApp()
        openAddSheet(in: app)
        enter(
            "https://www.tiktok.com/@ladle/video/slow-green-curry",
            in: app
        )

        app.buttons["Import from link"].tap()

        XCTAssertTrue(
            app.staticTexts["Rescuing your recipe"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["Keep browsing"].tap()

        XCTAssertTrue(
            app.staticTexts["Slow Green Curry"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Parsing"].exists)
    }

    func testFailedImportExposesAllRecoveryActions() {
        let app = launchApp()

        let failedImport = app.buttons[
            "Import failed: Carbonara, from TikTok"
        ]
        XCTAssertTrue(failedImport.waitForExistence(timeout: 2))
        failedImport.tap()

        XCTAssertTrue(
            app.staticTexts["This recipe needs a hand"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts[
                "https://www.tiktok.com/@cook/video/carbonara"
            ].exists
        )
        XCTAssertTrue(app.buttons["Retry Import"].exists)
        XCTAssertTrue(app.buttons["Add correction notes"].exists)
        XCTAssertTrue(app.buttons["Paste recipe details"].exists)
        XCTAssertTrue(app.buttons["Create manually"].exists)
        capture("Failed import recovery", in: app)
    }

    func testReadyImportNavigatesAndDuplicateOffersBothChoices() {
        let app = launchApp()
        let importURL =
            "https://www.tiktok.com/@ladle/video/ready-green-curry"

        openAddSheet(in: app)
        enter(importURL, in: app)
        app.buttons["Import from link"].tap()

        XCTAssertTrue(
            app.staticTexts["Recipe ready"].waitForExistence(timeout: 4)
        )
        app.buttons["View Recipe"].tap()

        XCTAssertTrue(
            app.staticTexts["Imported recipe"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["Weeknight Green Curry"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["Back to recipes"].tap()

        openAddSheet(in: app)
        enter(importURL, in: app)
        app.buttons["Import from link"].tap()

        XCTAssertTrue(
            app.staticTexts["Already in your recipes"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["Open existing recipe"].exists)
        XCTAssertTrue(app.buttons["Import another copy"].exists)
        capture("Duplicate import choice", in: app)

        app.buttons["Open existing recipe"].tap()

        XCTAssertTrue(
            app.staticTexts["Saved recipe"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["Weeknight Green Curry"]
                .waitForExistence(timeout: 2)
        )
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ]
        app.launch()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 3)
        )
        return app
    }

    private func openAddSheet(in app: XCUIApplication) {
        app.buttons["Add Recipe"].tap()
        XCTAssertTrue(
            app.textFields["Recipe link"].waitForExistence(timeout: 2)
        )
    }

    private func enter(
        _ url: String,
        in app: XCUIApplication
    ) {
        let linkField = app.textFields["Recipe link"]
        linkField.tap()
        linkField.typeText(url)
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
