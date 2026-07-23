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
}

@MainActor
@Observable
final class AccountSession {
    private enum Key {
        static let onboardingComplete = "ladle.onboarding.complete"
        static let accountState = "ladle.account.state"
    }

    private let store: PreferenceStoring

    private(set) var state: AccountState
    private(set) var shouldPresentWelcome: Bool

    init(
        store: PreferenceStoring = UserDefaults.standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store

        if launchArguments.contains("-reset-onboarding") {
            store.removeObject(forKey: Key.onboardingComplete)
            store.removeObject(forKey: Key.accountState)
        }

        if launchArguments.contains("-onboarding-complete") {
            store.set(true, forKey: Key.onboardingComplete)
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
    }

    func continueAsGuest() {
        completeWelcome(as: .guest)
    }

    func createFreeAccount() {
        completeWelcome(as: .freeAccount)
    }

    func signInWithApple() {
        completeWelcome(as: .signedInWithApple)
    }

    func saveDecision(savedRecipeCount: Int) -> GuestSaveDecision {
        switch state {
        case .guest, .undecided:
            GuestPolicy.decision(savedRecipeCount: savedRecipeCount)
        case .freeAccount, .signedInWithApple:
            .allow
        }
    }

    private func completeWelcome(as state: AccountState) {
        self.state = state
        shouldPresentWelcome = false
        store.set(state.rawValue, forKey: Key.accountState)
        store.set(true, forKey: Key.onboardingComplete)
    }
}
