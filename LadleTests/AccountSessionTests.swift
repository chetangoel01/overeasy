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
        session.applyRemoteUserKind("free")

        XCTAssertEqual(session.state, .freeAccount)
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 10),
            .allow
        )
    }

    func testRemoteSessionReadinessTracksAuthenticationAndSignOut() {
        let session = AccountSession(store: InMemoryPreferenceStore())

        XCTAssertFalse(session.isRemoteSessionReady)

        session.applyRemoteUserKind("guest")

        XCTAssertTrue(session.isRemoteSessionReady)

        session.signOut()

        XCTAssertFalse(session.isRemoteSessionReady)
    }

    func testGoogleAccountRestoresAsAnUnlimitedSignedInAccount() {
        let store = InMemoryPreferenceStore()
        let session = AccountSession(store: store)

        session.applyRemoteUserKind("google")
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
