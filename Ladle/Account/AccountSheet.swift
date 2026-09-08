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
            return "\(unchanged) \(failure.message)"
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

/// Deleting the account, as something a test can fail and then retry.
///
/// The sheet is handed the deletion as a closure, so this holds on to the
/// last one it ran: a 5xx means the account is still there and the same
/// request is still the right one to send. Deliberately not the sheet's own
/// `@State` booleans — Retry has to re-issue a request, and a button inside
/// an `.alert` is not something a unit test can reach.
@MainActor
@Observable
final class AccountDeleter {
    private(set) var isDeleting = false
    private(set) var didDelete = false
    var failure: AccountDeletionFailure?
    private var lastRequest: (@MainActor () async throws -> Void)?

    func delete(
        _ request: @escaping @MainActor () async throws -> Void
    ) async {
        guard !isDeleting else { return }
        isDeleting = true
        failure = nil
        lastRequest = request
        defer { isDeleting = false }
        do {
            try await request()
            lastRequest = nil
            didDelete = true
        } catch {
            failure = AccountDeletionFailure(error)
        }
    }

    /// Whether the alert should offer to send the deletion again. A quota or
    /// an expired session would answer the same way twice.
    func canRetry(at date: Date = .now) -> Bool {
        lastRequest != nil && failure?.canRetry(at: date) == true
    }

    func retry() async {
        guard let lastRequest else { return }
        await delete(lastRequest)
    }
}

/// Profile: the cook, then their settings, as a standard grouped form.
///
/// This was a `ScrollView` of hand-built cards: custom section headers in
/// large bold primary text where a grouped list uses small secondary ones,
/// 64-point rows where the system uses 44, hand-drawn dividers with a derived
/// inset, and circular icon badges. All of it re-implemented what `Form`
/// already does, and none of it matched the platform.
///
/// Notably it does not override the list background either: a grouped form
/// on the system's own ground is what a settings screen looks like on iOS.
///
/// Rows and headers only: every section's explanatory footer is gone. They
/// narrated what a cook could already read — "Tints buttons, favorites, and
/// the selected tab." under five colored circles — and five paragraphs of it
/// buried the person the screen is now led by. The copy that has to be read
/// before something irreversible happens still exists, in the confirmation
/// dialog and the alert where it is actually load-bearing.
struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue

    let accountSession: AccountSession
    let library: LibraryViewModel
    let syncStatus: SyncStatus
    var appIcon = AppIconStore()
    var authClient: AuthClient?
    var googleSignIn: (any GoogleSignInProviding)?
    var onAuthenticated: @MainActor () async -> Void = {}
    let signOut: @MainActor () async -> Void
    let deleteAccount: @MainActor () async throws -> Void

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSigningOut = false
    @State private var deletion = AccountDeleter()

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                librarySection
                appearanceSection
                if appIcon.canChooseAnIcon {
                    appIconSection
                }
                privacySection
                accountActionsSection
            }
            .listRowBackground(LadleTheme.Surface.raised)
            .scrollContentBackground(.hidden)
            // The diet is changed in the menu under the cook's name, so the
            // question about the icon is asked here, where the answer that
            // raised it was given.
            .onChange(of: library.filters.diets) { _, diets in
                appIcon.offerIfNeeded(for: diets)
            }
            .plantBasedIconOffer(appIcon)
            // The form's own first-section inset, replaced by the system's
            // ordinary one. Left alone it opened the sheet on a band of
            // nothing between the bar and the cook's face; the header
            // contributes no top padding of its own, so this is the whole
            // gap.
            .contentMargins(.top, Self.firstSectionInset, for: .scrollContent)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Profile")
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
            // Try Again re-issues the deletion. The account is still there
            // — that is what the message says — so the alert now offers the
            // request again rather than only a way out of itself.
            .alert(
                "Account could not be deleted",
                isPresented: Binding(
                    get: { deletion.failure != nil },
                    set: { if !$0 { deletion.failure = nil } }
                )
            ) {
                if deletion.canRetry() {
                    Button("Try Again") {
                        Task { await deletion.retry(); dismissIfDeleted() }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(deletion.failure?.message ?? "Please try again.")
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// The gap between the navigation bar and the cook's face.
    ///
    /// A grouped form's own first-section inset runs to about 35 points, and
    /// the header used to add 24 of its own on top of it. The system's
    /// ordinary first-section spacing is what a settings screen opens on, so
    /// that is what this is.
    private static let firstSectionInset = LadleTheme.Spacing.generous

    /// The cook, above their settings. This was a `LabeledContent` row with
    /// a status pill — the same row for a guest and for a signed-in account,
    /// saying nothing about who was signed in.
    private var accountSection: some View {
        Section {
            AccountHeaderView(
                accountSession: accountSession,
                library: library,
                authClient: authClient,
                googleSignIn: googleSignIn,
                onAuthenticated: onAuthenticated
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
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
            // The welcome screen used to spell this out under the guest
            // button, where it was a wall of small print in front of someone
            // who had not started yet. It belongs here, next to the count it
            // actually constrains, and only for the accounts it applies to.
            if accountSession.state == .guest {
                LabeledContent(
                    "Guest limit",
                    value: "\(Self.guestRecipeLimit) recipes"
                )
            }
        }
    }

    /// Matches the limit the import flow enforces and the guest-limit sheet
    /// quotes.
    private static let guestRecipeLimit = 10

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
        }
        .sensoryFeedback(.selection, trigger: accentColor)
    }

    /// The same row as the accent, one step down: a row of choices, the one
    /// in use carrying a check, and no confirmation of our own — iOS puts up
    /// its own notice when an icon changes, and a second one in front of it
    /// would only be us asking whether the cook meant the tap they just made.
    ///
    /// Independent of the diet offer. This is where any cook changes their
    /// mind, in either direction, whatever they eat.
    private var appIconSection: some View {
        Section {
            HStack(spacing: LadleTheme.Spacing.compact) {
                ForEach(LadleAppIcon.allCases) { option in
                    Button {
                        Task { await appIcon.select(option) }
                    } label: {
                        iconTile(option)
                    }
                    .buttonStyle(LadlePressButtonStyle())
                    .accessibilityLabel(option.title)
                    .accessibilityValue(
                        appIcon.icon == option ? "Selected" : ""
                    )
                    .accessibilityIdentifier(option.accessibilityIdentifier)
                }
            }
            .padding(.vertical, LadleTheme.Spacing.tight)
        } header: {
            Text("App icon")
        }
        .sensoryFeedback(.selection, trigger: appIcon.icon)
    }

    private func iconTile(_ option: LadleAppIcon) -> some View {
        Image(option.markImageName)
            .resizable()
            .scaledToFill()
            .frame(
                width: Self.appIconTileSize,
                height: Self.appIconTileSize
            )
            .clipShape(
                RoundedRectangle(
                    cornerRadius: LadleTheme.Corner.thumbnail,
                    style: .continuous
                )
            )
            .overlay {
                if appIcon.icon == option {
                    RoundedRectangle(
                        cornerRadius: LadleTheme.Corner.thumbnail,
                        style: .continuous
                    )
                    .strokeBorder(selectedAccent.actionColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if appIcon.icon == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(
                            .system(
                                size: LadleTheme.IconSize.large,
                                weight: .bold
                            )
                        )
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            LadleTheme.Label.onAccent,
                            selectedAccent.actionColor
                        )
                        .offset(x: LadleTheme.Spacing.tight, y: LadleTheme.Spacing.tight)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }

    /// A home-screen icon, near enough: big enough to recognise the mark,
    /// small enough that two of them are a row rather than a gallery.
    private static let appIconTileSize: CGFloat = 60

    private var privacySection: some View {
        Section {
            NavigationLink {
                PrivacyDetailView()
            } label: {
                Label("Privacy & data", systemImage: "hand.raised")
            }
            .accessibilityIdentifier("account.privacy")
        }
    }

    private var accountActionsSection: some View {
        Section {
            Button {
                isSignOutConfirmationPresented = true
            } label: {
                actionLabel("Sign out", isLoading: isSigningOut)
            }
            .disabled(isSigningOut || deletion.isDeleting)
            .accessibilityIdentifier("account.sign-out")

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                actionLabel("Delete account", isLoading: deletion.isDeleting)
            }
            .disabled(deletion.isDeleting || isSigningOut)
            .accessibilityIdentifier("account.delete")
        } header: {
            Text("Account")
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
        guard !isSigningOut, !deletion.isDeleting else {
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
        guard !isSigningOut else { return }
        Task { @MainActor in
            await deletion.delete(deleteAccount)
            dismissIfDeleted()
        }
    }

    private func dismissIfDeleted() {
        if deletion.didDelete {
            dismiss()
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
