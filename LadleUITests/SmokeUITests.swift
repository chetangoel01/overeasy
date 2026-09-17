import XCTest

/// The whole UI suite: a few journeys, each a critical path that only a
/// running app can prove. Every test here is a full app launch, so a rule or
/// a state belongs in a unit test instead, and a layout fix is recorded with
/// captures under `docs/verification/`.
///
/// Journeys are found by accessibility identifier, or by the label a cook
/// would press; none of them asserts copy, frames or screenshots.
final class SmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    // MARK: - Library and cooking

    @MainActor
    func testPrimaryJourneyCapturesInboxDetailAndCooking() {
        let app = launch()

        // The journey starts where a cold launch lands.
        let discover = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(discover.isSelected)
        XCTAssertTrue(
            app.descendants(matching: .any)["library.discover"].exists
        )

        app.tabBars.buttons["Inbox"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.import-inbox.root"]
                .waitForExistence(timeout: 3)
        )

        app.tabBars.buttons["Recipes"].tap()
        let recipe = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'recipe.grid.'")
        ).firstMatch
        XCTAssertTrue(recipe.waitForExistence(timeout: 3))
        recipe.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["recipe.detail"]
                .waitForExistence(timeout: 3)
        )

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

        app.buttons["Focus mode"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["cooking.focus-mode"]
                .waitForExistence(timeout: 3)
        )
    }

    /// Scaling a recipe from the band's inline stepper, end to end, on the
    /// seeded demo library.
    @MainActor
    func testChangingTheYieldRewritesTheIngredientAmounts() {
        let app = launch(startingOn: "Recipes")

        // The card's identifier carries the slug in both the grid and the
        // gallery, so this does not depend on which view mode a fresh
        // library opens in, nor on where the recipe sorts.
        let smashBurgers = app.buttons.matching(
            NSPredicate(
                format: "identifier ENDSWITH 'crispy-chili-oil-smash-burgers'"
            )
        ).firstMatch
        XCTAssertTrue(smashBurgers.waitForExistence(timeout: 5))
        smashBurgers.tap()

        // At the count the recipe claims, the row is the amount as stored.
        let asWritten = app.staticTexts[
            "1 lb ground beef — 80/20, in four loose balls"
        ]
        XCTAssertTrue(asWritten.waitForExistence(timeout: 5))

        // Four servings to eight, on the band itself: no sheet, no Done. The
        // stepper is one adjustable element to VoiceOver, so the test presses
        // where a finger does — the plus is the trailing end of the control.
        let servings = app.descendants(matching: .any)["recipe.servings"]
        XCTAssertTrue(servings.waitForExistence(timeout: 3))
        let plus = servings.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        )
        for _ in 0..<4 {
            plus.tap()
        }
        XCTAssertTrue(
            app.staticTexts["2 lb ground beef — 80/20, in four loose balls"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(asWritten.exists)
    }

    /// A failed sync keeps the saved library on screen and says so in the
    /// strip, which is drawn for a failure and nothing else.
    @MainActor
    func testOfflineContentScenarioPreservesRecipes() {
        let app = launch(
            ["-demo-scenario", "offline-content"],
            startingOn: "Recipes"
        )

        XCTAssertTrue(
            app.descendants(matching: .any)["sync.status"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Crispy Chili Oil Smash Burgers"].exists)
    }

    // MARK: - Import

    /// Issue #91. The import that needs review is the one whose row used to
    /// outlive its own review, and tapping the leftover row opened the
    /// failed-import sheet because the job named no recipe at all.
    @MainActor
    func testReviewedImportLeavesTheInbox() {
        let app = launch(startingOn: "Recipes")

        app.buttons["Add recipe"].tap()
        let link = app.textFields["Recipe link"]
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        link.tap()
        link.typeText("https://www.instagram.com/reel/needs-review-ragu")
        app.buttons["Import from link"].tap()

        // Leave by the door that keeps the tab bar: the point of the test is
        // the Inbox row, not the sheet's own shortcut to the recipe.
        let backToRecipes = app.buttons["Back to recipes"]
        XCTAssertTrue(backToRecipes.waitForExistence(timeout: 10))
        backToRecipes.tap()

        app.tabBars.buttons["Inbox"].tap()
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Sunday Tomato Ragu'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let rowIdentifier = row.identifier

        row.tap()
        let markReviewed = app.buttons["recipe.complete-review"]
        for _ in 0..<6 where !markReviewed.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            markReviewed.waitForExistence(timeout: 5),
            "The Inbox row should open the recipe for review, not a sheet"
        )
        // Completing a review pops back by itself, to the Inbox while any
        // import is still actionable.
        markReviewed.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.import-inbox.root"]
                .waitForExistence(timeout: 5)
        )

        let leftover = app.descendants(matching: .any)[rowIdentifier]
        XCTAssertTrue(
            leftover.waitForNonExistence(timeout: 5),
            "A reviewed import should not keep its Inbox row"
        )
    }

    // MARK: - Discover and Watch

    @MainActor
    func testDiscoverRecipeSupportsTapAndLongPress() {
        let app = launch(startingOn: "Discover")

        // A row's identifier is `discover.<original URL>`, so match the
        // scheme too: plain `discover.` also catches `discover.sort`, which
        // precedes the rows in the hierarchy on a Discover-first launch.
        // The scheme is also what keeps this on an "All recipes" row rather
        // than a shelf card, whose identifier is
        // `discover.card.<shelf>.<original URL>`.
        let row = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'discover.http'")
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))

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
        let viewRecipe = app.buttons["View Recipe"]
        XCTAssertTrue(viewRecipe.waitForExistence(timeout: 2))

        // The pushed page is the read-only Discover preview: it offers the
        // save, and carries none of the library's options.
        viewRecipe.tap()
        XCTAssertTrue(app.buttons["recipe.save"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Recipe options"].exists)
    }

    @MainActor
    func testWatchDefaultsToInlinePlayerWithPlaybackControls() {
        let app = launch(startingOn: "Watch")

        let player = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'watch.player.'")
        ).firstMatch
        XCTAssertTrue(player.waitForExistence(timeout: 3))

        // The controls are live rather than drawn: pausing offers resume.
        let pause = app.buttons["Pause video"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 2))
        pause.tap()
        XCTAssertTrue(
            app.buttons["Resume video"].firstMatch.waitForExistence(timeout: 2)
        )

        // Inline means the video never hands the cook to Safari, which is
        // only worth saying once the player has made its main navigation.
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
    }

    // MARK: - Profile and first run

    /// Google always sends a name, so the field arrives filled in and the
    /// cook only has to agree with it. There is no `AuthClient` under
    /// `-ui-testing`, so the account and the pending step come from launch
    /// arguments.
    @MainActor
    func testNameStepArrivesPrefilledAndContinueLandsInTheLibrary() {
        let app = launch([
            "-name-step-pending",
            "-account-state",
            "signedInWithGoogle",
            "-account-display-name",
            "Priya Raman",
        ])

        let field = app.textFields["name-step.name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Priya Raman")

        let contin = app.buttons["name-step.continue"]
        XCTAssertTrue(contin.isEnabled)
        contin.tap()

        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 5))
    }

    /// The row scrolls sideways, so its last icon starts off screen: reach it
    /// and choose it through the real system switch.
    @MainActor
    func testTheLastIconInTheRowCanBeReachedAndChosen() {
        let app = launch()
        let profile = app.buttons["Profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        XCTAssertTrue(app.navigationBars["Profile"].waitForExistence(timeout: 3))

        let mushroom = revealIcon("mushroom", in: app)
        mushroom.tap()
        dismissIconChangeNotice()
        waitForSelection(of: mushroom)

        // The installed icon outlives the run. Put the egg back, so the next
        // run starts from the default and still has a switch to prove.
        let egg = revealIcon("egg", in: app)
        egg.tap()
        dismissIconChangeNotice()
        waitForSelection(of: egg)
    }

    /// Scrolls the form to the picker, then the row to the tile: the row
    /// scrolls sideways, so a tile can be off either end of it. The drag ends
    /// on a hold, so the row settles on the nearest tile rather than being
    /// flung past the one it is after.
    @MainActor
    private func revealIcon(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let tile = app.buttons["account.app-icon.\(name)"]
        for _ in 0..<10 {
            if tile.exists && tile.isHittable && app.frame.contains(tile.frame) {
                return tile
            }
            if !tile.exists || tile.frame.maxY > app.frame.maxY {
                app.swipeUp()
            } else if tile.frame.minY < app.frame.minY {
                app.swipeDown()
            } else {
                let start = app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: app.frame.midX, dy: tile.frame.midY))
                let travel: CGFloat = tile.frame.midX > app.frame.midX ? -150 : 150
                start.press(
                    forDuration: 0.05,
                    thenDragTo: start.withOffset(CGVector(dx: travel, dy: 0)),
                    withVelocity: .slow,
                    thenHoldForDuration: 0.2
                )
            }
        }
        XCTAssertTrue(tile.isHittable, "Icon is not reachable: \(name)")
        return tile
    }

    /// The selection is the icon iOS reports as installed, read back after
    /// the switch, so it arrives a moment after the tap.
    @MainActor
    private func waitForSelection(of tile: XCUIElement) {
        let name = tile.label
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Selected"),
            object: tile
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [selected], timeout: 10),
            .completed,
            "\(name) was tapped but is not the installed icon"
        )
    }

    /// iOS puts up its own notice when an icon changes — "You have changed
    /// the icon for Overeasy" — and it is deliberately not suppressed. The
    /// notice belongs to SpringBoard rather than to the app, which is where
    /// it is answered from here; leaving it up would block the next tap.
    ///
    /// Not asserted: it arrives on its own schedule, sometimes after the tap
    /// that caused it has already returned, and a run that has not met it
    /// yet has still switched the icon. What proves the switch is the
    /// selection.
    @MainActor
    private func dismissIconChangeNotice() {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let notice = springboard.alerts.firstMatch
        guard notice.waitForExistence(timeout: 2) else { return }
        let confirmation = notice.buttons["OK"]
        (confirmation.exists
            ? confirmation
            : notice.buttons.firstMatch).tap()
    }

    // MARK: - Launch

    /// Every journey starts from the seeded demo app with onboarding answered
    /// and the library's preferences reset, so a diet or a view mode left in
    /// the simulator by one run cannot reach the next. A launch lands on
    /// Discover, so a journey about another tab has to ask for it rather
    /// than assume the first screen is its own.
    @MainActor
    private func launch(
        _ extraArguments: [String] = [],
        startingOn tab: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
        ] + extraArguments
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
}
