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

/// What the account knows about the cook: whatever the provider supplied at
/// sign-in, plus whatever they have since edited. Both parts are optional —
/// a guest has neither, and an Apple cook has no avatar, ever.
struct AccountProfile: Equatable, Sendable {
    /// The bound the server enforces on `display_name`. A formatted Apple
    /// name can exceed it, and a request that does is rejected outright, so
    /// every producer of a name clamps to this.
    static let displayNameLimit = 64

    var displayName: String?
    var avatarURL: URL?

    var isEmpty: Bool {
        displayName == nil && avatarURL == nil
    }

    var nonEmpty: AccountProfile? {
        isEmpty ? nil : self
    }

    /// The one or two initials a monogram draws when there is no photo.
    var monogram: String? {
        guard let displayName else { return nil }
        let initials = displayName
            .split(separator: " ")
            .compactMap(\.first)
            .prefix(2)
        return initials.isEmpty ? nil : String(initials).uppercased()
    }
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

    /// Set only by `-account-display-name` / `-account-avatar-url` under
    /// `-ui-testing`. A UI-test build has no `AuthClient` at all, so without
    /// this the header has no cook to draw and cannot be captured or
    /// asserted on.
    private let isProfilePinned: Bool

    private(set) var state: AccountState
    private(set) var shouldPresentWelcome: Bool
    private(set) var shouldPresentWalkthrough: Bool
    private(set) var isRemoteSessionReady = false
    private(set) var profile: AccountProfile?

    init(
        store: PreferenceStoring = UserDefaults.standard,
        launchArguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        self.store = store

        let isUITesting = launchArguments.contains("-ui-testing")
        let pinnedState: AccountState? =
            isUITesting ? Self.pinnedState(in: launchArguments) : nil
        isStatePinned = pinnedState != nil
        let pinnedProfile: AccountProfile? =
            isUITesting ? Self.pinnedProfile(in: launchArguments) : nil
        isProfilePinned = pinnedProfile != nil
        profile = pinnedProfile

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

    /// `-account-display-name <name>` and `-account-avatar-url <url>`,
    /// honoured only alongside `-ui-testing`.
    private static func pinnedProfile(
        in launchArguments: [String]
    ) -> AccountProfile? {
        AccountProfile(
            displayName: value(of: "-account-display-name", in: launchArguments),
            avatarURL: value(of: "-account-avatar-url", in: launchArguments)
                .flatMap(URL.init(string:))
        )
        .nonEmpty
    }

    private static func value(
        of argument: String,
        in launchArguments: [String]
    ) -> String? {
        guard
            let index = launchArguments.firstIndex(of: argument),
            launchArguments.indices.contains(index + 1)
        else { return nil }
        return launchArguments[index + 1]
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

    /// The backend's answer about this account: its kind, and the profile
    /// that travels with the tokens.
    func applyRemoteAccount(kind: String, profile: AccountProfile? = nil) {
        isRemoteSessionReady = true
        applyRemoteProfile(profile)
        // A pinned state still wants the session to come up — the library and
        // Discover need it — it just does not want the guest registration that
        // brings it to reset what was pinned.
        guard !isStatePinned else { return }
        switch kind {
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

    /// The server is authoritative about the profile too: it arrives with the
    /// tokens, is refreshed with them, and is replaced — not merged — by what
    /// the account currently holds.
    func applyRemoteProfile(_ profile: AccountProfile?) {
        guard !isProfilePinned else { return }
        self.profile = profile?.nonEmpty
    }

    /// The cook's own edit, as the server echoed it back.
    ///
    /// Unlike a session answer this applies even to a pinned profile: the pin
    /// stops the guest registration from wiping a fixture, not the person
    /// using the app — and without this the name is uneditable in exactly the
    /// builds a reviewer can run.
    func applyProfile(_ profile: AccountProfile?) {
        self.profile = profile?.nonEmpty
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
        // Whoever uses this device next is not the cook who just left.
        profile = nil
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
