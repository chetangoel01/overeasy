import XCTest

/// Profile, and the name step that fills it in.
///
/// There is no `AuthClient` under `-ui-testing`, so the account, the profile
/// and the pending name step all come from launch arguments — the same way
/// `-account-state` is the only reason a signed-in screen can be reached in
/// a UI test at all.
final class ProfileSheetUITests: XCTestCase {
    /// The correction that motivated most of this change: the sheet used to
    /// open on a band of nothing between the bar and the cook's face — the
    /// form's own first-section inset with the header's 24 points of padding
    /// stacked on top of it, 59 points in all. The system's ordinary
    /// first-section spacing is what it opens on now.
    ///
    /// Asserted rather than eyeballed, with room for the platform to move:
    /// what would regress is the padding coming back, and that is 35 points
    /// away in either direction.
    @MainActor
    func testProfileOpensOnTheCookRatherThanOnEmptySpace() {
        let app = launchSignedIn()

        let profile = app.buttons["Profile"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()

        let bar = app.navigationBars["Profile"]
        XCTAssertTrue(bar.waitForExistence(timeout: 3))
        let avatar = app.descendants(matching: .any)["account.profile.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 3))

        let gap = avatar.frame.minY - bar.frame.maxY
        XCTAssertEqual(
            gap,
            24,
            accuracy: 6,
            "The first section sits \(gap) points below the bar"
        )
        XCTAssertEqual(
            avatar.frame.height,
            96,
            accuracy: 1,
            "The avatar is the subject of the screen, not a row on it"
        )
    }

    /// Every footer is gone. These four strings were the whole of the case
    /// against them: prose narrating rows a cook can already read.
    @MainActor
    func testProfileHasNoExplanatoryFooters() {
        let app = launchSignedIn()

        app.buttons["Profile"].tap()
        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 3)
        )

        for footer in [
            "Your recipes stay synced across your devices.",
            "Tints buttons, favorites, and the selected tab.",
        ] {
            XCTAssertFalse(
                app.staticTexts[footer].exists,
                "Footer still present: \(footer)"
            )
        }
        XCTAssertTrue(app.staticTexts["Appearance"].exists)

        // The icon picker sits between Appearance and the rest, which put
        // the last two sections below the fold. A `Form` does not render
        // what is off screen, so saying what is *not* there is only worth
        // anything once they are on it.
        app.swipeUp()
        XCTAssertTrue(
            app.staticTexts["Account"].waitForExistence(timeout: 3)
        )
        for footer in [
            "What Overeasy stores, and what it never does.",
            "Signing out keeps your synced library in Overeasy. Deleting removes it permanently.",
        ] {
            XCTAssertFalse(
                app.staticTexts[footer].exists,
                "Footer still present: \(footer)"
            )
        }
        XCTAssertFalse(app.staticTexts["Account actions"].exists)
    }

    /// A guest gets the same header without an invented photo or name, and
    /// their own count of what is on the device.
    @MainActor
    func testGuestProfileOffersSignInAndCountsThisDevice() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
            "-account-state",
            "guest",
        ]
        app.launch()

        app.buttons["Profile"].tap()
        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Guest"].exists)
        XCTAssertTrue(app.buttons["account.profile.sign-in"].exists)

        let facts = app.descendants(matching: .any)["account.profile.facts"]
        XCTAssertTrue(facts.waitForExistence(timeout: 2))
        XCTAssertTrue(
            facts.label.hasSuffix("on this device"),
            "Guest facts read \(facts.label)"
        )
    }

    /// The avatar is a menu for every signed-in cook, and it offers to take
    /// the photo away only when the photo is theirs to take away. A provider's
    /// copy is not ours to remove — the account still has it either way.
    ///
    /// "Take Photo" is deliberately not asserted either way: whether a
    /// simulator reports a camera has changed between iOS versions, and the
    /// item's presence is `isSourceTypeAvailable(.camera)`, not this change.
    @MainActor
    func testAvatarMenuOffersAPhotoAndNoRemoveForAProvidersPicture() {
        let app = launchSignedIn()

        openAvatarMenu(in: app)

        XCTAssertTrue(
            app.buttons["Choose Photo"].waitForExistence(timeout: 3),
            "The avatar menu offers a photo to every signed-in cook"
        )
        XCTAssertFalse(app.buttons["Remove Photo"].exists)
    }

    @MainActor
    func testAvatarMenuRemovesOnlyThePhotoTheCookChose() {
        let app = launchSignedIn(photoIsTheCooks: true)

        openAvatarMenu(in: app)

        XCTAssertTrue(app.buttons["Choose Photo"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Remove Photo"].exists)
    }

    @MainActor
    private func openAvatarMenu(in app: XCUIApplication) {
        app.buttons["Profile"].tap()
        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 3)
        )
        let avatar = app.descendants(matching: .any)["account.profile.avatar"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 3))
        avatar.tap()
    }

    // MARK: - The app icon

    /// The picker beside the accent, switching the icon for real.
    ///
    /// Which icon is on at the start is not assumed: the installed icon
    /// belongs to the device and outlives the app's container, so the test
    /// reads the selection, taps the other one, and puts it back — which
    /// also exercises both directions.
    ///
    /// iOS confirms an icon change with an alert of its own. It is not
    /// suppressed, so dismissing it is part of the flow.
    @MainActor
    func testTheIconIsSwitchedInProfileAndBothWaysBack() {
        let app = launchSignedIn()

        app.buttons["Profile"].tap()
        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 3)
        )

        let egg = app.descendants(matching: .any)["account.app-icon.egg"]
        let plantBased = app.descendants(matching: .any)[
            "account.app-icon.plant-based"
        ]
        XCTAssertTrue(
            egg.waitForExistence(timeout: 3),
            "Profile offers the two icons beside the accent"
        )
        XCTAssertTrue(plantBased.exists)
        if !egg.isHittable {
            app.swipeUp()
        }

        let startedOnTheEgg = egg.value as? String == "Selected"
        let other = startedOnTheEgg ? plantBased : egg
        let original = startedOnTheEgg ? egg : plantBased

        other.tap()
        dismissIconChangeNotice()
        waitForSelection(of: other)
        XCTAssertNotEqual(original.value as? String, "Selected")

        // Put the device back the way it was found: the icon survives the
        // app, so a test that switched it would hand the next one a
        // different starting point.
        original.tap()
        dismissIconChangeNotice()
        waitForSelection(of: original)
    }

    /// The selection is the icon iOS reports as installed, read back after
    /// the switch, so it arrives a moment after the tap.
    @MainActor
    private func waitForSelection(of tile: XCUIElement) {
        expectation(
            for: NSPredicate(format: "value == %@", "Selected"),
            evaluatedWith: tile
        )
        waitForExpectations(timeout: 10) { error in
            XCTAssertNil(
                error,
                "\(tile.label) was tapped but is not the installed icon"
            )
        }
    }

    /// iOS puts up its own notice when an icon changes — "You have changed
    /// the icon for Overeasy" — and it is deliberately not suppressed. The
    /// notice belongs to SpringBoard rather than to the app, which is where
    /// it is answered from here; leaving it up would block the next tap.
    ///
    /// Not asserted: it arrives on its own schedule, sometimes after the tap
    /// that caused it has already returned, and a run that has not met it
    /// yet has still switched the icon. What proves the switch is the
    /// selection, below.
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

    // MARK: - The diet

    /// The one place a diet changes after onboarding, and it has to be
    /// believable from the library: choose it beside the name, close the
    /// sheet, and the recipes are already narrowed.
    @MainActor
    func testTheDietIsChangedBesideTheNameAndTheLibraryFollows() {
        let app = launchSignedIn()

        app.buttons["Profile"].tap()
        XCTAssertTrue(
            app.navigationBars["Profile"].waitForExistence(timeout: 3)
        )

        let diet = app.descendants(matching: .any)["account.profile.diet"]
        XCTAssertTrue(
            diet.waitForExistence(timeout: 3),
            "A cook who has no diet yet is still offered one, beside the name"
        )
        XCTAssertEqual(diet.value as? String, "Add a diet")
        diet.tap()

        let vegetarian = app.buttons["Vegetarian"]
        XCTAssertTrue(vegetarian.waitForExistence(timeout: 3))
        vegetarian.tap()

        // The diet is what raises the icon question, and this is the other
        // place it can be set: the offer follows the answer that caused it,
        // in the sheet the cook is standing in. Declined here — the diet is
        // what this test is about, and nothing switches on its own.
        let offer = app.alerts["Prefer an icon without the egg?"]
        XCTAssertTrue(
            offer.waitForExistence(timeout: 5),
            "A diet set in Profile raises the icon question there"
        )
        offer.buttons["Keep the egg"].tap()

        XCTAssertEqual(
            app.descendants(matching: .any)["account.profile.diet"]
                .value as? String,
            "Vegetarian diet"
        )

        app.buttons["Close"].tap()
        app.tabBars.firstMatch.buttons["Recipes"].tap()

        // Four of the demo's six dishes are vegetarian.
        XCTAssertTrue(
            app.staticTexts["4 recipes"].waitForExistence(timeout: 5),
            "A diet set in Profile is on everywhere at once"
        )
        XCTAssertTrue(
            app.buttons["Remove filter: Vegetarian diet"].exists
        )
    }

    // MARK: - The name step

    /// Google always sends a name, so the field arrives filled in and the
    /// cook only has to agree with it.
    @MainActor
    func testNameStepArrivesPrefilledAndContinueLandsInTheLibrary() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-name-step-pending",
            "-reset-library-preferences",
            "-account-state",
            "signedInWithGoogle",
            "-account-display-name",
            "Priya Raman",
        ]
        app.launch()

        let field = app.textFields["name-step.name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Priya Raman")
        XCTAssertTrue(app.staticTexts["What should we call you?"].exists)
        XCTAssertTrue(app.buttons["name-step.skip"].exists)

        // The screen asks one question and there is nothing else on it to
        // do, so the keyboard is already up.
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 3),
            "The name step raises the keyboard on arrival"
        )

        let contin = app.buttons["name-step.continue"]
        XCTAssertTrue(contin.isEnabled)
        contin.tap()

        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["What should we call you?"].exists)
    }

    /// Apple sends a name only on the very first authorization for an Apple
    /// ID and nothing afterwards, so the field can arrive empty — and
    /// Continue has nothing to submit until something is typed.
    @MainActor
    func testEmptyNameStepDisablesContinueUntilSomethingIsTyped() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-name-step-pending",
            "-reset-library-preferences",
            "-account-state",
            "signedInWithApple",
        ]
        app.launch()

        let field = app.textFields["name-step.name-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let contin = app.buttons["name-step.continue"]
        XCTAssertTrue(contin.exists)
        XCTAssertFalse(contin.isEnabled)

        // The field's own hit area is only the line of text, so the tap has
        // to land on the padded row around it. Typing without a preceding
        // tap would pass even if that row were dead.
        field.tap()
        field.typeText("Mira")
        XCTAssertTrue(contin.isEnabled)

        // Skip is the other way out, and never disabled.
        app.buttons["name-step.skip"].tap()
        XCTAssertTrue(app.tabBars.buttons["Recipes"].waitForExistence(timeout: 5))
    }

    @MainActor
    private func launchSignedIn(
        photoIsTheCooks: Bool = false
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-onboarding-complete",
            "-reset-library-preferences",
            "-account-state",
            "signedInWithGoogle",
            "-account-display-name",
            "Priya Raman",
            "-account-avatar-url",
            "https://i.pravatar.cc/300?img=47",
            "-account-created-at",
            "2026-08-14T12:00:00Z",
        ]
        if photoIsTheCooks {
            app.launchArguments.append("-account-avatar-custom")
        }
        app.launch()
        return app
    }
}
