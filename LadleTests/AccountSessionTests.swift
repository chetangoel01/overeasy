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

    func testGuestSaveDecisionWarnsBeforeTenthRecipe() {
        let session = AccountSession(store: InMemoryPreferenceStore())
        session.continueAsGuest()

        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 9),
            .allowWithAccountPrompt
        )
        XCTAssertEqual(
            session.saveDecision(savedRecipeCount: 10),
            .limitReached
        )
    }

    func testFreeAccountRemovesGuestSaveLimit() {
        let session = AccountSession(store: InMemoryPreferenceStore())
        session.createFreeAccount()

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
