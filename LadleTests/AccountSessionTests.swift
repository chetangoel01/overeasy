import LadleCore
import XCTest
@testable import Ladle

@MainActor
final class AccountSessionTests: XCTestCase {
    func testNewInstallPresentsWelcome() {
        let session = AccountSession(store: InMemoryPreferenceStore())

        XCTAssertTrue(session.shouldPresentWelcome)
        XCTAssertEqual(session.state, .undecided)
    }

    func testContinuingAsGuestPersistsTheChoice() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.continueAsGuest()
        let returningSession = AccountSession(store: store)

        XCTAssertFalse(returningSession.shouldPresentWelcome)
        XCTAssertEqual(returningSession.state, .guest)
    }

    func testFirstAccountChoicePresentsWalkthroughUntilCompleted() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.signInWithGoogle()

        XCTAssertFalse(session.shouldPresentWelcome)
        XCTAssertTrue(session.shouldPresentWalkthrough)

        session.completeWalkthrough()
        let returningSession = AccountSession(store: store)

        XCTAssertFalse(session.shouldPresentWalkthrough)
        XCTAssertFalse(returningSession.shouldPresentWelcome)
        XCTAssertFalse(returningSession.shouldPresentWalkthrough)
    }

    func testIncompleteWalkthroughResumesAfterRelaunch() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.continueAsGuest()
        let returningSession = AccountSession(store: store)

        XCTAssertTrue(returningSession.shouldPresentWalkthrough)
    }

    func testCompletedWalkthroughDoesNotReplayAfterSignOut() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)
        session.signInWithApple()
        session.completeWalkthrough()

        session.signOut()
        session.signInWithApple()

        XCTAssertFalse(session.shouldPresentWalkthrough)
    }

    // MARK: - The name step

    func testSigningUpAsksForANameOnceAndNeverAgain() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.signInWithGoogle()
        XCTAssertTrue(session.shouldPresentNameStep)

        session.completeNameStep()
        XCTAssertFalse(session.shouldPresentNameStep)

        let returningSession = AccountSession(store: store)
        XCTAssertFalse(returningSession.shouldPresentNameStep)
    }

    /// Quitting mid-step is not answering it. The pending flag is persisted
    /// before the screen appears, so the next launch asks again.
    func testAnUnfinishedNameStepResumesAfterRelaunch() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.signInWithApple()

        XCTAssertTrue(AccountSession(store: store).shouldPresentNameStep)
        XCTAssertTrue(session.shouldPresentNameStep)
    }

    /// Restoring a session is not signing up. Every cold launch runs the
    /// backend's answer back through the same path a sign-in takes, so
    /// without a transition check every cook already signed in when this
    /// shipped would have been asked their name once on upgrade.
    func testARestoredSessionIsNotAskedForANameAgain() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)
        session.signInWithGoogle()
        session.completeNameStep()
        session.completeWalkthrough()

        let relaunched = AccountSession(store: store)
        relaunched.applyRemoteAccount(kind: "google")

        XCTAssertFalse(relaunched.shouldPresentNameStep)
    }

    /// The same restore, part-way through the step: this one has to resume.
    func testARestoredSessionResumesAnUnfinishedNameStep() {
        let store = InMemoryPreferenceStore()
        AccountSession(store: store).signInWithGoogle()

        let relaunched = AccountSession(store: store)
        XCTAssertTrue(relaunched.shouldPresentNameStep)
        relaunched.applyRemoteAccount(kind: "google")

        XCTAssertTrue(relaunched.shouldPresentNameStep)
    }

    /// The case that caught this on the simulator: a device whose stored
    /// account kind outlived its onboarding flags reached the welcome screen
    /// with `state` already Apple, so a gate that asked "was the previous
    /// state not an account?" said no and skipped the step. What separates a
    /// sign-in from a restore is that the sign-in *changes* the account.
    func testSigningInOverAStaleAccountStateStillAsks() {
        let store = InMemoryPreferenceStore()
        store.set(AccountState.signedInWithApple.rawValue, forKey: "ladle.account.state")
        let session = AccountSession(store: store)
        XCTAssertTrue(session.shouldPresentWelcome)

        session.signInWithGoogle()

        XCTAssertTrue(session.shouldPresentNameStep)
    }

    func testGuestsAreNeverAskedForAName() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.continueAsGuest()

        XCTAssertFalse(session.shouldPresentNameStep)
        XCTAssertFalse(AccountSession(store: store).shouldPresentNameStep)
    }

    /// A guest who signs in later reaches the step through the same path a
    /// new account does — `completeWelcome`, once the backend has confirmed.
    func testAGuestWhoSignsInLaterIsAsked() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)
        session.continueAsGuest()
        session.completeWalkthrough()

        session.applyRemoteAccount(kind: "google")

        XCTAssertTrue(session.shouldPresentNameStep)
        XCTAssertFalse(session.shouldPresentWalkthrough)
    }

    /// The name belongs to the account, not the device — unlike the
    /// walkthrough, which the device only has to be taught once.
    func testSigningOutAsksTheNextCookForTheirOwnName() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)
        session.signInWithApple()
        session.completeNameStep()

        session.signOut()
        XCTAssertFalse(session.shouldPresentNameStep)
        session.signInWithApple()

        XCTAssertTrue(session.shouldPresentNameStep)
    }

    func testOnboardingCompleteArgumentSkipsTheNameStep() {
        let store = InMemoryPreferenceStore()

        let session = AccountSession(
            store: store,
            launchArguments: [
                "-ui-testing",
                "-onboarding-complete",
                "-account-state",
                "signedInWithGoogle",
            ]
        )

        XCTAssertFalse(session.shouldPresentNameStep)
        XCTAssertFalse(session.shouldPresentWalkthrough)
    }

    func testNameStepArgumentsSkipAndForceTheStep() {
        let store = InMemoryPreferenceStore()
        let signedIn = AccountSession(store: store)
        signedIn.signInWithGoogle()
        XCTAssertTrue(signedIn.shouldPresentNameStep)

        let skipped = AccountSession(
            store: store,
            launchArguments: ["-name-step-complete"]
        )
        XCTAssertFalse(skipped.shouldPresentNameStep)

        // The force is read last, so it wins over both the skip and
        // `-onboarding-complete`.
        let forced = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: [
                "-ui-testing",
                "-onboarding-complete",
                "-name-step-pending",
                "-account-state",
                "signedInWithApple",
            ]
        )
        XCTAssertTrue(forced.shouldPresentNameStep)

        // Forcing it for a guest still shows nothing: there is no account
        // to put a name on.
        let guest = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: [
                "-ui-testing",
                "-onboarding-complete",
                "-name-step-pending",
                "-account-state",
                "guest",
            ]
        )
        XCTAssertFalse(guest.shouldPresentNameStep)
    }

    func testGuestSaveDecisionWarnsBeforeTenthRecipe() {
        let session = AccountSession(store: InMemoryPreferenceStore())
        session.continueAsGuest()

        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 0),
            .allow
        )
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 8),
            .allow
        )
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 9),
            .allowWithAccountPrompt
        )
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 10),
            .limitReached
        )
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 11),
            .limitReached
        )
    }

    func testBackendConfirmedAccountRemovesGuestSaveLimit() {
        let session = AccountSession(store: InMemoryPreferenceStore())
        session.continueAsGuest()

        // Only a user kind reported by the backend can lift the cap; there
        // is no local action that mints an account.
        session.applyRemoteAccount(kind: "free")

        XCTAssertEqual(session.state, .freeAccount)
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 10),
            .allow
        )
    }

    func testRemoteSessionReadinessTracksAuthenticationAndSignOut() {
        let session = AccountSession(store: InMemoryPreferenceStore())

        XCTAssertFalse(session.isRemoteSessionReady)

        session.applyRemoteAccount(kind: "guest")

        XCTAssertTrue(session.isRemoteSessionReady)

        session.signOut()

        XCTAssertFalse(session.isRemoteSessionReady)
    }

    func testRemoteProfileIsAppliedWithTheAccountAndClearedOnSignOut() {
        let session = AccountSession(store: InMemoryPreferenceStore())

        session.applyRemoteAccount(
            kind: "google",
            profile: AccountProfile(
                displayName: "Priya Raman",
                avatarURL: URL(string: "https://cdn.test/priya.jpg")
            )
        )

        XCTAssertEqual(session.state, .signedInWithGoogle)
        XCTAssertEqual(session.profile?.displayName, "Priya Raman")
        XCTAssertEqual(
            session.profile?.avatarURL,
            URL(string: "https://cdn.test/priya.jpg")
        )

        session.signOut()

        XCTAssertNil(
            session.profile,
            "The next cook on this device must not inherit a name"
        )
    }

    /// An account with no profile yet — every Apple cook who signed in before
    /// the name was captured — is a signed-in account, not a broken one.
    func testAccountWithoutAProfileStaysSignedIn() {
        let session = AccountSession(store: InMemoryPreferenceStore())

        session.applyRemoteAccount(kind: "apple", profile: nil)

        XCTAssertEqual(session.state, .signedInWithApple)
        XCTAssertNil(session.profile)
    }

    /// Under `-ui-testing` there is no `AuthClient`, so the header has no
    /// profile to draw unless the launch arguments supply one.
    func testUITestingLaunchArgumentsPinTheProfile() {
        let session = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: [
                "-ui-testing",
                "-account-state", "signedInWithGoogle",
                "-account-display-name", "Priya Raman",
                "-account-avatar-url", "https://cdn.test/priya.jpg",
            ]
        )

        XCTAssertEqual(session.state, .signedInWithGoogle)
        XCTAssertEqual(session.profile?.displayName, "Priya Raman")
        XCTAssertEqual(
            session.profile?.avatarURL,
            URL(string: "https://cdn.test/priya.jpg")
        )

        // The guest registration that still runs must not wipe what was
        // pinned, exactly as it must not wipe the pinned state.
        session.applyRemoteAccount(kind: "guest", profile: nil)

        XCTAssertEqual(session.state, .signedInWithGoogle)
        XCTAssertEqual(session.profile?.displayName, "Priya Raman")

        // The cook's own edit is not the guest registration, and must land
        // even here — otherwise the name is uneditable in exactly the builds
        // a reviewer can run.
        session.applyProfile(AccountProfile(displayName: "Priya R."))

        XCTAssertEqual(session.profile?.displayName, "Priya R.")
    }

    /// `-account-created-at` completes the `-account-*` set: a UI-test build
    /// has no `AuthClient`, so without it the facts line has no month and
    /// "cooking since" cannot be captured or asserted on. Written the way a
    /// person types it on a command line, without the wire's `.000`.
    func testPinnedCreationDateReachesTheProfile() {
        let session = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: [
                "-ui-testing",
                "-account-display-name",
                "Priya Raman",
                "-account-created-at",
                "2026-08-14T12:00:00Z",
            ]
        )

        XCTAssertEqual(
            session.profile?.createdAt,
            ISO8601DateFormatter().date(from: "2026-08-14T12:00:00Z")
        )
    }

    /// A date on its own is a profile: a guest has no name and no avatar,
    /// and the guest facts line still has a device count to print beside it.
    func testACreationDateAloneIsEnoughOfAProfile() {
        let session = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: [
                "-ui-testing",
                "-account-created-at",
                "2026-08-14T12:00:00Z",
            ]
        )

        XCTAssertNotNil(session.profile)
        XCTAssertNil(session.profile?.displayName)
    }

    func testProfileNameIsIgnoredWithoutTheUITestingArgument() {
        let session = AccountSession(
            store: InMemoryPreferenceStore(),
            launchArguments: ["-account-display-name", "Priya Raman"]
        )

        XCTAssertNil(session.profile)
    }

    func testGoogleAccountRestoresAsAnUnlimitedSignedInAccount() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.applyRemoteAccount(kind: "google")
        let returningSession = AccountSession(store: store)

        XCTAssertTrue(session.isRemoteSessionReady)
        XCTAssertEqual(session.state, .signedInWithGoogle)
        XCTAssertEqual(returningSession.state, .signedInWithGoogle)
        XCTAssertFalse(returningSession.shouldPresentWelcome)
        XCTAssertEqual(
            returningSession.saveDecision(savedRecipeCount: 10),
            .allow
        )
    }
}

private final class InMemoryPreferenceStore: PreferenceStoring {
    private var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool {
        values[defaultName] as? Bool ?? false
    }

    func string(forKey defaultName: String) -> String? {
        values[defaultName] as? String
    }

    func set(_ value: Any?, forKey defaultName: String) {
        values[defaultName] = value
    }

    func removeObject(forKey defaultName: String) {
        values.removeValue(forKey: defaultName)
    }
}
