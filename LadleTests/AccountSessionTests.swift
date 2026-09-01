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
