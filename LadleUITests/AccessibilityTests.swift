import XCTest

@MainActor
final class AccessibilityTests: XCTestCase {
    func testAccessibilityLargeWelcomeKeepsEntryActionsUsable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-reset-onboarding",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Recipes, rescued from the scroll."]
                .waitForExistence(timeout: 3)
        )
        let apple = app.buttons["Continue with Apple"]
        let guest = app.buttons["Try as a guest"]
        XCTAssertTrue(apple.exists)
        XCTAssertTrue(guest.exists)
        assertMinimumHitTarget(apple)
        assertMinimumHitTarget(guest)
        XCTAssertLessThanOrEqual(guest.frame.maxY, app.frame.maxY - 12)
        capture("Accessibility Large Welcome", in: app)
    }

    func testAccessibilityLargeLibraryKeepsPrimaryControlsUsable() {
        let app = launchApp()

        let addRecipe = app.buttons["Add Recipe"]
        XCTAssertTrue(addRecipe.waitForExistence(timeout: 2))
        assertMinimumHitTarget(addRecipe)

        let search = app.buttons["Search"]
        XCTAssertTrue(search.exists)
        assertMinimumHitTarget(search)

        let inbox = element(in: app, identifier: "library.import-inbox")
        XCTAssertTrue(inbox.waitForExistence(timeout: 2))
        inbox.tap()
        XCTAssertTrue(
            app.staticTexts["Import inbox"].waitForExistence(timeout: 2)
        )
        let inboxScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(inboxScrollView.waitForExistence(timeout: 2))
        let importGuide = app.staticTexts["How imports work"]
        for _ in 0..<5 {
            if importGuide.exists {
                break
            }
            inboxScrollView.swipeUp()
        }
        XCTAssertTrue(importGuide.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Parsing"].exists)
        XCTAssertTrue(app.staticTexts["Needs review"].exists)
        XCTAssertTrue(app.staticTexts["Failed"].exists)
        capture("Accessibility Large Library Header", in: app)

        app.buttons["Back"].tap()
        openAllRecipes(in: app)
        let recipe = app.buttons.matching(
            identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
        )
        .firstMatch
        scrollToHittable(recipe, in: app)
        XCTAssertTrue(recipe.waitForExistence(timeout: 2))
        XCTAssertTrue(recipe.isHittable)
        capture("Accessibility Large Library", in: app)
    }

    func testAccessibilityLargeCookingControlsRemainHittable() {
        let app = launchApp()
        openAllRecipes(in: app)

        let recipe = element(
            in: app,
            identifier: "recipe.grid.one-pot-lemon-orzo-with-feta"
        )
        scrollToHittable(recipe, in: app)
        XCTAssertTrue(recipe.waitForExistence(timeout: 2))
        recipe.tap()

        let startCooking = app.buttons["Start Cooking"]
        XCTAssertTrue(startCooking.waitForExistence(timeout: 2))
        scrollToHittable(startCooking, in: app)
        assertMinimumHitTarget(startCooking)
        startCooking.tap()

        let focusMode = app.buttons["Focus mode"]
        XCTAssertTrue(focusMode.waitForExistence(timeout: 2))
        scrollToHittable(focusMode, in: app)
        assertMinimumHitTarget(focusMode)
        focusMode.tap()

        let nextStep = app.buttons["Next step"]
        XCTAssertTrue(nextStep.waitForExistence(timeout: 2))
        assertMinimumHitTarget(nextStep)
        nextStep.tap()

        let timer = app.buttons["Start Simmer orzo timer, 12:00"]
        XCTAssertTrue(timer.waitForExistence(timeout: 2))
        assertMinimumHitTarget(timer)
        capture("Accessibility Large Focus Mode", in: app)
    }

    func testAccessibilityLargeAccountKeepsSignOutReachable() {
        let app = launchApp()
        app.buttons["Account"].tap()

        XCTAssertTrue(
            app.staticTexts["Your account"].waitForExistence(timeout: 2)
        )

        let signOut = element(in: app, identifier: "account.sign-out")
        scrollToHittable(signOut, in: app)
        for _ in 0..<2
            where signOut.frame.maxY > app.frame.maxY - 12 {
            app.swipeUp()
        }
        XCTAssertTrue(signOut.isHittable)
        XCTAssertLessThanOrEqual(signOut.frame.maxY, app.frame.maxY - 12)
        assertMinimumHitTarget(signOut)
        capture("Accessibility Large Account", in: app)
    }

    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityL",
        ]
        app.launch()
        XCTAssertTrue(
            element(in: app, identifier: "library.root")
                .waitForExistence(timeout: 3)
        )
        return app
    }

    private func openAllRecipes(in app: XCUIApplication) {
        let allRecipes = app.buttons["All 6"]
        XCTAssertTrue(allRecipes.waitForExistence(timeout: 2))
        allRecipes.tap()
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

    private func element(
        in app: XCUIApplication,
        identifier: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func scrollToHittable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 {
            if element.isHittable {
                return
            }
            app.swipeUp()
        }
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
