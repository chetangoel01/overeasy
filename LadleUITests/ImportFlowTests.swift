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
                "Tip: sharing a video to Overeasy is even faster."
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
            app.staticTexts["Cracking this one open"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["Keep browsing"].tap()

        let inbox = button(
            in: app,
            labelStartingWith: "Import inbox"
        )
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        inbox.tap()
        let parsingCard = element(
            in: app,
            labelContaining: "Slow Green Curry"
        )
        XCTAssertTrue(parsingCard.waitForExistence(timeout: 2))
        XCTAssertTrue(parsingCard.label.contains("Parsing"))
    }

    func testFailedImportExposesAllRecoveryActions() {
        let app = launchApp()

        let inbox = button(
            in: app,
            labelStartingWith: "Import inbox"
        )
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        inbox.tap()
        let failedImport = element(
            in: app,
            labelContaining: "Carbonara"
        )
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
        XCTAssertTrue(app.buttons["Retry import"].exists)
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
            app.staticTexts["Ready, over easy"].waitForExistence(timeout: 4)
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
            element(in: app, identifier: "recipe.detail")
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.staticTexts["Weeknight Green Curry"]
                .waitForExistence(timeout: 2)
        )
    }

    func testLiveBackendImportsTikTokAndInstagram() throws {
        let sources = [
            "https://www.tiktok.com/@mishkamakesfood/video/7655788084671401247",
            "https://www.instagram.com/reel/Cx8pqZDv7G0/",
        ]

        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-onboarding-complete",
            "-reset-library-preferences",
            "-reset-backend-session",
        ]
        app.launch()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 15)
        )
        XCTAssertTrue(
            waitUntilEnabledAndHittable(
                app.buttons["Add Recipe"],
                timeout: 15
            ),
            "Guest authentication did not become ready."
        )

        for source in sources {
            importFromLiveBackend(source, in: app)
        }
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

    private func importFromLiveBackend(
        _ url: String,
        in app: XCUIApplication
    ) {
        openAddSheet(in: app)
        enter(url, in: app)
        app.buttons["Import from link"].tap()

        let duplicate = app.staticTexts["Already in your recipes"]
        let ready = app.staticTexts["Recipe saved"]
        let review = app.staticTexts["Recipe needs review"]
        let failed = app.staticTexts["We saved the link"]

        XCTAssertTrue(
            waitForAny(
                [duplicate, ready, review, failed],
                timeout: 90
            ),
            "The backend did not return a terminal state for \(url)."
        )
        XCTAssertFalse(
            failed.exists,
            "The live backend failed to import \(url)."
        )

        if duplicate.exists {
            app.buttons["Import another copy"].tap()
            XCTAssertTrue(
                waitForAny([ready, review, failed], timeout: 90),
                "The duplicate import did not reach a terminal state for \(url)."
            )
            XCTAssertFalse(
                failed.exists,
                "The live backend failed to re-import \(url)."
            )
        }

        app.buttons["View Recipe"].tap()
        XCTAssertTrue(
            element(in: app, identifier: "recipe.detail")
                .waitForExistence(timeout: 5)
        )
        app.buttons["Back to recipes"].tap()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 5)
        )
    }

    private func waitForAny(
        _ elements: [XCUIElement],
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: \.exists) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return elements.contains(where: \.exists)
    }

    private func waitUntilEnabledAndHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(
                        format:
                            "isEnabled == true AND isHittable == true"
                    ),
                    object: element
                ),
            ],
            timeout: timeout
        ) == .completed
    }

    private func element(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func element(
        in app: XCUIApplication,
        labelContaining text: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@",
                    text
                )
            )
            .firstMatch
    }

    private func button(
        in app: XCUIApplication,
        labelStartingWith text: String
    ) -> XCUIElement {
        app.buttons
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH[c] %@",
                    text
                )
            )
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
