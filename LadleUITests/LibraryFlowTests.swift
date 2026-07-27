import XCTest

@MainActor
final class LibraryFlowTests: XCTestCase {
    func testLibraryShowsPendingStatesAndRecipeMetadata() {
        let app = launchApp()
        app.buttons["Home"].tap()

        let inbox = element(in: app, identifier: "library.import-inbox")
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        inbox.tap()
        XCTAssertTrue(
            app.staticTexts["Import inbox"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["How imports work"].exists)
        XCTAssertTrue(app.staticTexts["Parsing"].exists)
        XCTAssertTrue(app.staticTexts["Needs review"].exists)
        XCTAssertTrue(app.staticTexts["Import failed"].exists)
        capture("Library — pending imports", in: app)

        app.buttons["Back"].tap()
        app.buttons["All 6"].tap()
        app.swipeUp()

        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["16 g P · 35 min · ≈ 520 cal"].exists
        )
        XCTAssertTrue(
            app.buttons[
                "Add One-Pot Lemon Orzo with Feta to favorites"
            ].exists
        )
        capture("Library — recipe grid", in: app)
    }

    func testInboxSupportsSwipeDeleteAndInteractiveBackGesture() {
        let app = launchApp()
        app.buttons["Home"].tap()
        element(in: app, identifier: "library.import-inbox").tap()

        let failed = element(
            in: app,
            identifier: "import.FD53B35A-4E30-40BE-8D90-047908528103"
        )
        XCTAssertTrue(failed.waitForExistence(timeout: 2))
        failed.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(failed.exists)

        let screen = app.windows.firstMatch
        screen.coordinate(
            withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)
        )
        .press(
            forDuration: 0.05,
            thenDragTo: screen.coordinate(
                withNormalizedOffset: CGVector(dx: 0.82, dy: 0.5)
            )
        )

        XCTAssertTrue(
            element(in: app, identifier: "library.home")
                .waitForExistence(timeout: 2)
        )
    }

    func testPhysicalImportInboxCardTapOpensInboxInsteadOfWatch() {
        let app = launchApp(
            additionalArguments: ["-one-recipe-library"],
            allRecipesButtonTitle: "All 1"
        )
        app.buttons["Home"].tap()

        let inbox = element(
            in: app,
            identifier: "library.import-inbox"
        )
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        let watch = element(in: app, identifier: "library.watch")
        XCTAssertTrue(watch.waitForExistence(timeout: 2))
        let geometry = XCTAttachment(
            string: "Inbox: \(inbox.frame)\nWatch: \(watch.frame)"
        )
        geometry.name = "Library Home card frames"
        geometry.lifetime = .keepAlways
        add(geometry)
        capture("Library — physical Inbox tap geometry", in: app)

        let window = app.windows.firstMatch
        let origin = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        )
        let tapY = max(inbox.frame.midY, watch.frame.minY + 1)
        XCTAssertLessThan(tapY, inbox.frame.maxY)
        origin.withOffset(
            CGVector(dx: inbox.frame.midX, dy: tapY)
        )
        .tap()
        capture("Library — after physical Inbox tap", in: app)

        XCTAssertFalse(
            element(in: app, identifier: "library.watch.root")
                .waitForExistence(timeout: 1)
        )
        XCTAssertTrue(
            element(in: app, identifier: "library.import-inbox.root")
                .waitForExistence(timeout: 2)
        )
    }

    func testReviewedImportLeavesInboxAndInboxCanReopen() {
        let app = launchApp()
        app.buttons["Home"].tap()
        let inboxCard = element(
            in: app,
            identifier: "library.import-inbox"
        )
        inboxCard.tap()

        let reviewedImport = element(
            in: app,
            identifier: "import.FD53B35A-4E30-40BE-8D90-047908528102"
        )
        XCTAssertTrue(reviewedImport.waitForExistence(timeout: 2))
        reviewedImport.tap()

        let completeReview = element(
            in: app,
            identifier: "recipe.complete-review"
        )
        XCTAssertTrue(completeReview.waitForExistence(timeout: 2))
        app.swipeUp()
        completeReview.tap()

        XCTAssertTrue(
            element(in: app, identifier: "library.import-inbox.root")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(reviewedImport.exists)

        app.buttons["Back"].tap()
        XCTAssertTrue(inboxCard.waitForExistence(timeout: 2))
        inboxCard.tap()
        XCTAssertTrue(
            element(in: app, identifier: "library.import-inbox.root")
                .waitForExistence(timeout: 2)
        )
    }

    func testCompletingLastInboxReviewReturnsHome() {
        let app = launchApp()
        app.buttons["Home"].tap()
        element(in: app, identifier: "library.import-inbox").tap()

        deleteImport(
            "import.FD53B35A-4E30-40BE-8D90-047908528101",
            in: app
        )
        deleteImport(
            "import.FD53B35A-4E30-40BE-8D90-047908528103",
            in: app
        )

        let reviewedImport = element(
            in: app,
            identifier: "import.FD53B35A-4E30-40BE-8D90-047908528102"
        )
        reviewedImport.tap()

        let completeReview = element(
            in: app,
            identifier: "recipe.complete-review"
        )
        XCTAssertTrue(completeReview.waitForExistence(timeout: 2))
        app.swipeUp()
        completeReview.tap()

        XCTAssertTrue(
            element(in: app, identifier: "library.home")
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            element(in: app, identifier: "library.import-inbox").exists
        )
    }

    func testDarkHomeScrollsInboxAwayWithoutACloseControl() {
        let app = launchApp(
            additionalArguments: ["-AppleInterfaceStyle", "Dark"]
        )
        app.buttons["Home"].tap()
        let inbox = element(
            in: app,
            identifier: "library.import-inbox"
        )

        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Hide import inbox"].exists)
        capture("Library — dark Home", in: app)

        app.swipeUp()
        XCTAssertFalse(inbox.exists)
        capture("Library — dark Home, inbox scrolled away", in: app)

        app.swipeDown()
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        inbox.tap()
        XCTAssertTrue(
            app.staticTexts["Import inbox"].waitForExistence(timeout: 2)
        )
        capture("Library — dark Import Inbox", in: app)
    }

    func testDedicatedSearchAndListModeWork() {
        let app = launchApp()
        app.buttons["Search"].tap()

        let searchField = app.textFields[
            "Recipe, ingredient, or creator"
        ]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))

        searchField.tap()
        searchField.typeText("orzo")

        XCTAssertTrue(
            app.staticTexts["One-Pot Lemon Orzo with Feta"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            app.staticTexts["Crispy Chili Oil Smash Burgers"].exists
        )
        XCTAssertTrue(
            element(
                in: app,
                identifier: "recipe.list.one-pot-lemon-orzo-with-feta"
            )
            .exists
        )

        app.buttons["Back"].tap()
        XCTAssertTrue(
            element(in: app, identifier: "library.all-recipes")
                .waitForExistence(timeout: 2)
        )

        app.buttons["Show recipes as a list"].tap()

        XCTAssertTrue(
            element(
                in: app,
                identifier: "recipe.list.one-pot-lemon-orzo-with-feta"
            )
                .waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            element(
                in: app,
                identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
            )
                .exists
        )
        capture("Library — recipe list", in: app)
    }

    func testMaximumTimeFilterCanBeAppliedAndRemoved() {
        let app = launchApp()

        app.buttons["Filter recipes"].tap()

        let thirtyMinutes = app.buttons["30 minutes or less"]
        XCTAssertTrue(thirtyMinutes.waitForExistence(timeout: 2))
        capture("Library — filters", in: app)
        thirtyMinutes.tap()
        app.buttons["Apply Filters"].tap()

        let activeFilter = app.buttons["Remove filter: Up to 30 min"]
        XCTAssertTrue(activeFilter.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts["15-Minute Garlic Butter Udon"].exists
        )
        XCTAssertFalse(
            app.staticTexts["Sheet-Pan Gochujang Chicken"].exists
        )

        activeFilter.tap()

        XCTAssertFalse(activeFilter.exists)
    }

    func testFavoriteControlUpdatesItsAccessibleState() {
        let app = launchApp()
        app.swipeUp()

        let addFavorite = app.buttons[
            "Add One-Pot Lemon Orzo with Feta to favorites"
        ]
        XCTAssertTrue(addFavorite.waitForExistence(timeout: 2))

        addFavorite.tap()

        XCTAssertTrue(
            app.buttons[
                "Remove One-Pot Lemon Orzo with Feta from favorites"
            ]
            .waitForExistence(timeout: 2)
        )
    }

    func testWatchWorkspaceExposesCompleteAccessibleControls() {
        let app = launchApp()
        app.buttons["Home"].tap()

        let watch = element(in: app, identifier: "library.watch")
        XCTAssertTrue(watch.waitForExistence(timeout: 2))
        watch.tap()
        XCTAssertTrue(
            element(in: app, identifier: "library.watch.root")
                .waitForExistence(timeout: 2)
        )

        let share = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Share ")
        )
        .firstMatch
        XCTAssertTrue(share.exists)
        assertMinimumHitTarget(share)

        let favorite = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "favorites")
        )
        .firstMatch
        XCTAssertTrue(favorite.exists)
        assertMinimumHitTarget(favorite)

        for title in ["Overview", "Ingredients", "Method"] {
            let panel = app.buttons[title].firstMatch
            XCTAssertTrue(panel.exists)
            assertMinimumHitTarget(panel)
        }
        XCTAssertTrue(app.buttons["Play video"].exists)
        XCTAssertTrue(app.buttons["Open recipe"].exists)
        XCTAssertTrue(app.buttons["Start cooking"].exists)
        capture("Library — Watch workspace", in: app)
    }

    private func launchApp(
        additionalArguments: [String] = [],
        allRecipesButtonTitle: String = "All 6"
    ) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ] + additionalArguments
        app.launch()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 3)
        )
        let allRecipes = app.buttons[allRecipesButtonTitle]
        XCTAssertTrue(allRecipes.waitForExistence(timeout: 2))
        allRecipes.tap()
        return app
    }

    private func element(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func assertMinimumHitTarget(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertGreaterThanOrEqual(
            element.frame.width,
            43.5,
            file: file,
            line: line
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height,
            43.5,
            file: file,
            line: line
        )
    }

    private func deleteImport(
        _ identifier: String,
        in app: XCUIApplication
    ) {
        let importCard = element(in: app, identifier: identifier)
        XCTAssertTrue(importCard.waitForExistence(timeout: 2))
        importCard.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssertFalse(importCard.exists)
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
