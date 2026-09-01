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

    /// Set only by `-account-state` under `-ui-testing`. While it holds, the
    /// backend's answer no longer decides the account state.
    ///
    /// Nothing else can pin the state, and for a good reason: the backend is
    /// authoritative everywhere else, because a client that could assert its
    /// own account kind could assert its way past a quota. This exists so the
    /// signed-in screens can be run and asserted on at all — until it did,
    /// every launch registered a guest session and overwrote whatever local
    /// state said, so no UI test could reach them.
    private let isStatePinned: Bool

    private(set) var state: AccountState
    private(set) var shouldPresentWelcome: Bool
    private(set) var shouldPresentWalkthrough: Bool
    private(set) var isRemoteSessionReady = false

    init(
        store: PreferenceStoring = UserDefaults.standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store

        let pinnedState: AccountState? =
            launchArguments.contains("-ui-testing")
            ? Self.pinnedState(in: launchArguments)
            : nil
        isStatePinned = pinnedState != nil

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

        if let pinnedState {
            store.set(pinnedState.rawValue, forKey: Key.accountState)
        }
        let storedState = store.string(forKey: Key.accountState)
            .flatMap(AccountState.init(rawValue:))
        state = pinnedState ?? storedState ?? .undecided
        shouldPresentWelcome = !store.bool(
            forKey: Key.onboardingComplete
        )
        shouldPresentWalkthrough =
            store.bool(forKey: Key.walkthroughPending)
            && !store.bool(forKey: Key.walkthroughComplete)
    }

    /// `-account-state <value>`, honoured only alongside `-ui-testing`.
    private static func pinnedState(
        in launchArguments: [String]
    ) -> AccountState? {
        guard
            let index = launchArguments.firstIndex(of: "-account-state"),
            launchArguments.indices.contains(index + 1)
        else { return nil }
        return AccountState(rawValue: launchArguments[index + 1])
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
        // A pinned state still wants the session to come up — the library and
        // Discover need it — it just does not want the guest registration that
        // brings it to reset what was pinned.
        guard !isStatePinned else { return }
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
