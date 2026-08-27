import Foundation
import LadleCore
import Observation

protocol PreferenceStoring: AnyObject {
    func bool(forKey defaultName: String) -> Bool
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
    func removeObject(forKey defaultName: String)
}

extension UserDefaults: PreferenceStoring {}

enum AccountState: String, Equatable {
    case undecided
    case guest
    case freeAccount
    case signedInWithApple
    case signedInWithGoogle
}

@MainActor
@Observable
final class AccountSession {
    private enum Key {
        static let onboardingComplete = "ladle.onboarding.complete"
        static let walkthroughComplete = "ladle.walkthrough.complete"
        static let walkthroughPending = "ladle.walkthrough.pending"
        static let accountState = "ladle.account.state"
    }

    private let store: PreferenceStoring

    private(set) var state: AccountState
    private(set) var shouldPresentWelcome: Bool
    private(set) var shouldPresentWalkthrough: Bool
    private(set) var isRemoteSessionReady = false

    init(
        store: PreferenceStoring = UserDefaults.standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store

        if launchArguments.contains("-reset-onboarding") {
            store.removeObject(forKey: Key.onboardingComplete)
            store.removeObject(forKey: Key.walkthroughComplete)
            store.removeObject(forKey: Key.walkthroughPending)
            store.removeObject(forKey: Key.accountState)
        }

        if launchArguments.contains("-onboarding-complete") {
            store.set(true, forKey: Key.onboardingComplete)
            store.set(true, forKey: Key.walkthroughComplete)
            store.set(false, forKey: Key.walkthroughPending)
            if store.string(forKey: Key.accountState) == nil {
                store.set(
                    AccountState.guest.rawValue,
                    forKey: Key.accountState
                )
            }
        }

        let storedState = store.string(forKey: Key.accountState)
            .flatMap(AccountState.init(rawValue:))
        state = storedState ?? .undecided
        shouldPresentWelcome = !store.bool(
            forKey: Key.onboardingComplete
        )
        shouldPresentWalkthrough =
            store.bool(forKey: Key.walkthroughPending)
            && !store.bool(forKey: Key.walkthroughComplete)
    }

    func continueAsGuest() {
        completeWelcome(as: .guest)
    }

    func signInWithApple() {
        completeWelcome(as: .signedInWithApple)
    }

    func signInWithGoogle() {
        completeWelcome(as: .signedInWithGoogle)
    }

    func applyRemoteUserKind(_ userKind: String) {
        isRemoteSessionReady = true
        switch userKind {
        case "apple":
            completeWelcome(as: .signedInWithApple)
        case "google":
            completeWelcome(as: .signedInWithGoogle)
        case "guest":
            completeWelcome(as: .guest)
        default:
            completeWelcome(as: .freeAccount)
        }
    }

    func saveDecision(savedRecipeCount: Int) -> GuestSaveDecision {
        switch state {
        case .guest, .undecided:
            GuestPolicy.decision(savedRecipeCount: savedRecipeCount)
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            .allow
        }
    }

    func signOut() {
        state = .undecided
        shouldPresentWelcome = true
        shouldPresentWalkthrough = false
        isRemoteSessionReady = false
        store.removeObject(forKey: Key.accountState)
        store.set(false, forKey: Key.onboardingComplete)
        store.set(false, forKey: Key.walkthroughPending)
    }

    func completeWalkthrough() {
        shouldPresentWalkthrough = false
        store.set(true, forKey: Key.walkthroughComplete)
        store.set(false, forKey: Key.walkthroughPending)
    }

    private func completeWelcome(as state: AccountState) {
        self.state = state
        shouldPresentWelcome = false
        shouldPresentWalkthrough = !store.bool(
            forKey: Key.walkthroughComplete
        )
        store.set(state.rawValue, forKey: Key.accountState)
        store.set(true, forKey: Key.onboardingComplete)
        store.set(
            shouldPresentWalkthrough,
            forKey: Key.walkthroughPending
        )
    }
}
