import SwiftUI

struct AccountDeletionFailure: Equatable {
    let failure: RemoteFailure
    let requestID: UUID?

    init(failure: RemoteFailure, requestID: UUID? = nil) {
        self.failure = failure
        self.requestID = requestID
    }

    init?(_ error: any Error) {
        guard !(error is CancellationError) else {
            return nil
        }
        let report = RemoteFailureReport(error)
        self.init(failure: report.failure, requestID: report.requestID)
    }

    var retryAt: Date? { failure.retryAt }

    func canRetry(at date: Date = .now) -> Bool {
        failure.canRetry(at: date)
    }

    var message: String {
        let unchanged = "Your account and recipes are unchanged."
        switch failure {
        case .offline:
            return "\(unchanged) Reconnect and try again."
        case .serviceUnavailable:
            return "\(unchanged) The service is temporarily unavailable. Try again in a moment."
        case let .rateLimited(retryAt):
            return "\(unchanged) Try again after \(retryAt.formatted(date: .omitted, time: .shortened))."
        case .quotaExceeded:
            return "\(unchanged) Account deletion has reached its current limit."
        case .authenticationExpired:
            return "\(unchanged) Sign in again before deleting the account."
        case .invalidResponse:
            return "\(unchanged) Overeasy couldn’t read the service response. Try again."
        case .unknown:
            return "\(unchanged) Please try again."
        }
    }
}

/// Settings as a standard grouped form.
///
/// This was a `ScrollView` of hand-built cards: custom section headers in
/// large bold primary text where a grouped list uses small secondary ones,
/// 64-point rows where the system uses 44, hand-drawn dividers with a derived
/// inset, and circular icon badges. All of it re-implemented what `Form`
/// already does, and none of it matched the platform.
///
/// Notably it does not override the list background either: a grouped form
/// on the system's own ground is what a settings screen looks like on iOS.
struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue

    let accountSession: AccountSession
    let library: LibraryViewModel
    let syncStatus: SyncStatus
    var authClient: AuthClient?
    var googleSignIn: (any GoogleSignInProviding)?
    var onAuthenticated: @MainActor () async -> Void = {}
    let signOut: @MainActor () async -> Void
    let deleteAccount: @MainActor () async throws -> Void
    /// Variant A of issue #62 only: retitles the sheet "Profile" and leads it
    /// with the larger identity header. Every other section is untouched,
    /// which is the point of the variant. False in every shipping launch.
    var prototypeIdentity = false

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var deletionFailure: AccountDeletionFailure?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                librarySection
                appearanceSection
                privacySection
                accountActionsSection
            }
            .listRowBackground(LadleTheme.Surface.raised)
            .scrollContentBackground(.hidden)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle(prototypeIdentity ? "Profile" : "Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
            .confirmationDialog(
                "Sign out of Overeasy?",
                isPresented: $isSignOutConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Sign Out", role: .destructive) {
                    performSignOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Recipes are removed from this device but stay in your synced library."
                )
            }
            .alert(
                "Delete your Overeasy account?",
                isPresented: $isDeleteConfirmationPresented
            ) {
                Button("Delete Account", role: .destructive) {
                    performAccountDeletion()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Your synced recipes and account data will be permanently deleted. This can\u{2019}t be undone."
                )
            }
            .alert(
                "Account could not be deleted",
                isPresented: Binding(
                    get: { deletionFailure != nil },
                    set: { if !$0 { deletionFailure = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletionFailure?.message ?? "Please try again.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The cook, above their settings. This was a `LabeledContent` row with
    /// a status pill — the same row for a guest and for a signed-in account,
    /// saying nothing about who was signed in. The explanation stays a
    /// footer because that is where a grouped list puts prose about the
    /// section above it.
    private var accountSection: some View {
        Section {
            Group {
                if prototypeIdentity {
                    ProfileIdentityView(
                        accountSession: accountSession,
                        library: library,
                        diameter: 96,
                        authClient: authClient,
                        googleSignIn: googleSignIn,
                        onAuthenticated: onAuthenticated
                    )
                } else {
                    AccountHeaderView(
                        accountSession: accountSession,
                        authClient: authClient,
                        googleSignIn: googleSignIn,
                        onAuthenticated: onAuthenticated
                    )
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        } footer: {
            Text(Self.accountDetail(for: accountSession.state))
        }
    }

    private var librarySection: some View {
        Section("Library") {
            LabeledContent(
                "Saved recipes",
                value: "\(library.recipes.count)"
            )
            LabeledContent(
                "Sync",
                value: Self.syncValue(
                    for: accountSession.state,
                    status: syncStatus.state
                )
            )
        }
    }

    /// "Accent color" used to hang off the right of the header as a detail.
    /// iOS has no such affordance: what a section does is explained in its
    /// footer, so that is where it went.
    private var appearanceSection: some View {
        Section {
            HStack(spacing: LadleTheme.Spacing.compact) {
                ForEach(LadleAccentColor.allCases) { option in
                    Button {
                        accentColor = option.rawValue
                    } label: {
                        ZStack {
                            Circle()
                                .fill(option.actionColor)
                            if selectedAccent == option {
                                Image(systemName: "checkmark")
                                    .font(
                                        .system(
                                            size: LadleTheme.IconSize.small,
                                            weight: .bold
                                        )
                                    )
                                    .foregroundStyle(LadleTheme.Label.onAccent)
                            }
                        }
                        .frame(
                            width: LadleTheme.Control.hitTarget,
                            height: LadleTheme.Control.hitTarget
                        )
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LadlePressButtonStyle())
                    .accessibilityLabel(option.title)
                    .accessibilityValue(
                        selectedAccent == option ? "Selected" : ""
                    )
                }
            }
            .padding(.vertical, LadleTheme.Spacing.tight)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Tints buttons, favorites, and the selected tab.")
        }
        .sensoryFeedback(.selection, trigger: accentColor)
    }

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacyDetailView()
            } label: {
                Label("Privacy & data", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("account.privacy")
        } footer: {
            Text("What Overeasy stores, and what it never does.")
        }
    }

    private var accountActionsSection: some View {
        Section {
            Button {
                isSignOutConfirmationPresented = true
            } label: {
                actionLabel("Sign out", isLoading: isSigningOut)
            }
            .disabled(isSigningOut || isDeletingAccount)
            .accessibilityIdentifier("account.sign-out")

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                actionLabel("Delete account", isLoading: isDeletingAccount)
            }
            .disabled(isDeletingAccount || isSigningOut)
            .accessibilityIdentifier("account.delete")
        } header: {
            Text("Account actions")
        } footer: {
            Text(
                "Signing out keeps your synced library in Overeasy. Deleting removes it permanently."
            )
        }
    }

    /// Text only, no leading symbol. iOS puts destructive and account
    /// actions in plain rows, and a symbol here inherits the accent tint —
    /// which put a green trash can beside red "Delete account" text.
    private func actionLabel(
        _ title: String,
        isLoading: Bool
    ) -> some View {
        HStack {
            Text(title)
            if isLoading {
                Spacer()
                ProgressView()
            }
        }
    }

    private func performSignOut() {
        guard !isSigningOut, !isDeletingAccount else {
            return
        }
        isSigningOut = true
        Task { @MainActor in
            await signOut()
            isSigningOut = false
            dismiss()
        }
    }

    private func performAccountDeletion() {
        guard !isDeletingAccount, !isSigningOut else {
            return
        }
        isDeletingAccount = true
        deletionFailure = nil
        Task { @MainActor in
            defer { isDeletingAccount = false }
            do {
                try await deleteAccount()
                dismiss()
            } catch {
                deletionFailure = AccountDeletionFailure(error)
            }
        }
    }

    static func accountTitle(for state: AccountState) -> String {
        switch state {
        case .undecided: "Choose an account"
        case .guest: "Using Overeasy as a guest"
        case .freeAccount: "Signed in to Overeasy"
        case .signedInWithApple: "Signed in with Apple"
        case .signedInWithGoogle: "Signed in with Google"
        }
    }

    static func accountDetail(for state: AccountState) -> String {
        switch state {
        case .undecided:
            "Sign in to keep your recipes synced."
        case .guest:
            "Recipes stay on this device until you sign in."
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            "Your recipes stay synced across your devices."
        }
    }

    static func syncValue(
        for state: AccountState,
        status: SyncStatus.State
    ) -> String {
        switch state {
        case .undecided, .guest: "This device"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            status.shortLabel
        }
    }

    private var selectedAccent: LadleAccentColor {
        LadleAccentColor.resolve(storedValue: accentColor)
    }
}
