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
    /// Whether that URL is the photo the cook chose or the provider's own.
    /// It cannot be read off the URL — both are links — and the avatar menu
    /// has to know, because "Remove Photo" means something for one of them
    /// and nothing for the other. Deliberately not part of `isEmpty`: a flag
    /// about a picture is not itself something to show.
    var avatarIsCustom = false
    /// When the account was created, as the server reported it. Server-owned
    /// and never edited here; it is what "cooking since August 2026" reads.
    /// Optional because a guest session predating the field, or a Keychain
    /// record written by an older build, simply has no date to show.
    var createdAt: Date?

    var isEmpty: Bool {
        displayName == nil && avatarURL == nil && createdAt == nil
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
        static let nameStepComplete = "ladle.nameStep.complete"
        static let nameStepPending = "ladle.nameStep.pending"
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
    /// Whether the new cook is still owed the question about their name.
    ///
    /// Derived the way `shouldPresentWalkthrough` is — a pending flag that
    /// survives a relaunch, and a completion flag that ends it for good — so
    /// a cook who quits mid-step is asked again and one who answered or
    /// skipped never is. Only an Apple or Google sign-up is asked: a guest
    /// has no account to put a name on.
    private(set) var shouldPresentNameStep: Bool
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
            store.removeObject(forKey: Key.nameStepComplete)
            store.removeObject(forKey: Key.nameStepPending)
            store.removeObject(forKey: Key.accountState)
        }

        // The name step is part of onboarding, so `-onboarding-complete`
        // finishes it along with the walkthrough. Without that, one test
        // that left the step pending would strand every later test in the
        // run behind it — a UI-test container keeps its defaults.
        if launchArguments.contains("-onboarding-complete") {
            store.set(true, forKey: Key.onboardingComplete)
            store.set(true, forKey: Key.walkthroughComplete)
            store.set(false, forKey: Key.walkthroughPending)
            store.set(true, forKey: Key.nameStepComplete)
            store.set(false, forKey: Key.nameStepPending)
            if store.string(forKey: Key.accountState) == nil {
                store.set(
                    AccountState.guest.rawValue,
                    forKey: Key.accountState
                )
            }
        }

        // `-name-step-complete` skips the step on its own, for a capture or
        // a test that wants the library without the rest of onboarding.
        // `-name-step-pending` forces it, and is read last so it wins.
        if launchArguments.contains("-name-step-complete") {
            store.set(true, forKey: Key.nameStepComplete)
            store.set(false, forKey: Key.nameStepPending)
        }
        if launchArguments.contains("-name-step-pending") {
            store.set(false, forKey: Key.nameStepComplete)
            store.set(true, forKey: Key.nameStepPending)
        }

        if let pinnedState {
            store.set(pinnedState.rawValue, forKey: Key.accountState)
        }
        let storedState = store.string(forKey: Key.accountState)
            .flatMap(AccountState.init(rawValue:))
        let resolvedState = pinnedState ?? storedState ?? .undecided
        state = resolvedState
        shouldPresentWelcome = !store.bool(
            forKey: Key.onboardingComplete
        )
        shouldPresentWalkthrough =
            store.bool(forKey: Key.walkthroughPending)
            && !store.bool(forKey: Key.walkthroughComplete)
        shouldPresentNameStep =
            Self.asksForName(resolvedState)
            && store.bool(forKey: Key.nameStepPending)
            && !store.bool(forKey: Key.nameStepComplete)
    }

    /// Only a real account is asked for a name. A guest has nothing to put
    /// one on, and `undecided` has not chosen yet.
    private static func asksForName(_ state: AccountState) -> Bool {
        switch state {
        case .undecided, .guest, .freeAccount:
            false
        case .signedInWithApple, .signedInWithGoogle:
            true
        }
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

    /// `-account-display-name <name>`, `-account-avatar-url <url>`,
    /// `-account-avatar-custom` and `-account-created-at <ISO 8601>`,
    /// honoured only alongside `-ui-testing`. The date is read without
    /// fractional seconds — the form a person types on a command line,
    /// `2026-08-14T12:00:00Z` — rather than the wire's `.000Z`, which nothing
    /// here has to round-trip.
    ///
    /// `-account-avatar-custom` is a bare flag beside the URL, because that
    /// is the only difference a test can otherwise not create: the same
    /// picture is a provider's or the cook's own depending on it, and only
    /// one of those offers to remove it.
    private static func pinnedProfile(
        in launchArguments: [String]
    ) -> AccountProfile? {
        AccountProfile(
            displayName: value(of: "-account-display-name", in: launchArguments),
            avatarURL: value(of: "-account-avatar-url", in: launchArguments)
                .flatMap(URL.init(string:)),
            avatarIsCustom: launchArguments.contains("-account-avatar-custom"),
            createdAt: value(of: "-account-created-at", in: launchArguments)
                .flatMap(ISO8601DateFormatter().date(from:))
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
        shouldPresentNameStep = false
        isRemoteSessionReady = false
        // Whoever uses this device next is not the cook who just left.
        profile = nil
        store.removeObject(forKey: Key.accountState)
        store.set(false, forKey: Key.onboardingComplete)
        store.set(false, forKey: Key.walkthroughPending)
        // Unlike the walkthrough, which teaches the device the app once,
        // the name belongs to the account. Whoever signs in next is a new
        // cook and gets asked their own.
        store.set(false, forKey: Key.nameStepComplete)
        store.set(false, forKey: Key.nameStepPending)
    }

    /// Answered or skipped — both end the step for good, because a cook
    /// who declined to give a name has answered the question.
    func completeNameStep() {
        shouldPresentNameStep = false
        store.set(true, forKey: Key.nameStepComplete)
        store.set(false, forKey: Key.nameStepPending)
    }

    func completeWalkthrough() {
        shouldPresentWalkthrough = false
        store.set(true, forKey: Key.walkthroughComplete)
        store.set(false, forKey: Key.walkthroughPending)
    }

    private func completeWelcome(as state: AccountState) {
        // A sign-in, not a session being restored. `restoreSession` runs
        // this on every cold launch, re-asserting the account the app is
        // already in — so a cook signed in before the step existed must not
        // be stopped on their way into the app by a question about their
        // name. What separates the two is that a sign-in *changes* the
        // account: undecided or guest becomes Apple or Google. A restore
        // hands back the kind it was given.
        let isNewSignIn = self.state != state
        self.state = state
        shouldPresentWelcome = false
        shouldPresentNameStep =
            Self.asksForName(state)
            && !store.bool(forKey: Key.nameStepComplete)
            // ...but a relaunch part-way through the step resumes it, and
            // that relaunch is a restore rather than a sign-in.
            && (isNewSignIn || store.bool(forKey: Key.nameStepPending))
        shouldPresentWalkthrough = !store.bool(
            forKey: Key.walkthroughComplete
        )
        store.set(state.rawValue, forKey: Key.accountState)
        store.set(true, forKey: Key.onboardingComplete)
        store.set(shouldPresentNameStep, forKey: Key.nameStepPending)
        store.set(
            shouldPresentWalkthrough,
            forKey: Key.walkthroughPending
        )
    }
}
