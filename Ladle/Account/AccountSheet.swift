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

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.ladleAccent) private var accent
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue

    let accountSession: AccountSession
    let library: LibraryViewModel
    let syncStatus: SyncStatus
    let signOut: @MainActor () async -> Void
    let deleteAccount: @MainActor () async throws -> Void

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var deletionFailure: AccountDeletionFailure?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(
                    alignment: .leading,
                    spacing: LadleTheme.Spacing.cooking
                ) {
                    accountSummary
                    librarySection
                    appearanceSection
                    privacySection
                    accountActionsSection
                }
                .padding(.horizontal, LadleTheme.Spacing.generous)
                .padding(.top, LadleTheme.Spacing.regular)
                .padding(.bottom, LadleTheme.Spacing.cooking)
            }
            .scrollIndicators(.hidden)
            .background(LadleTheme.Surface.porcelain)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: dismiss.callAsFunction)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LadleTheme.Surface.porcelain)
    }

    private var accountSummary: some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.regular) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: LadleTheme.IconSize.feature, weight: .semibold))
                .foregroundStyle(accent.label)
                .frame(width: 52, height: 52)
                .background(LadleTheme.Surface.badge, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
                Text(Self.accountTitle(for: accountSession.state))
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.Label.primary)

                Text(Self.accountDetail(for: accountSession.state))
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                LadlePill(
                    text: accountStatus,
                    systemImage: accountStatusSymbol,
                    tint: accountStatusTint
                )
            }

            Spacer(minLength: 0)
        }
        .padding(LadleTheme.Spacing.regular)
        .background(LadleTheme.Surface.raised, in: accountShape)
        .overlay {
            accountShape
                .stroke(LadleTheme.Label.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            LadleSectionHeader(title: "Library")

            VStack(spacing: 0) {
                infoRow(
                    icon: "book.closed",
                    title: "Saved recipes",
                    value: "\(library.recipes.count)"
                )
                accountDivider
                infoRow(
                    icon: "arrow.triangle.2.circlepath",
                    title: "Sync",
                    value: Self.syncValue(
                        for: accountSession.state,
                        status: syncStatus.state
                    )
                )
            }
            .background(LadleTheme.Surface.raised, in: accountShape)
            .overlay {
                accountShape
                    .stroke(LadleTheme.Label.primary.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Privacy")

            NavigationLink {
                PrivacyDetailView()
            } label: {
                HStack(spacing: LadleTheme.Layout.iconGap) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: LadleTheme.IconSize.medium, weight: .semibold))
                        .foregroundStyle(accent.label)
                        .frame(width: Self.rowIconWidth, height: Self.rowIconWidth)
                        .background(LadleTheme.Surface.badge, in: Circle())
                    VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                        Text("Privacy & data")
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.Label.primary)
                        Text("What Overeasy stores, and what it never does")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.Label.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                        .foregroundStyle(LadleTheme.Label.secondary)
                }
                .padding(.horizontal, LadleTheme.Layout.cardPadding)
                .padding(.vertical, LadleTheme.Spacing.medium)
                .frame(minHeight: LadleTheme.Control.primary)
                .background(LadleTheme.Surface.raised, in: accountShape)
                .overlay {
                    accountShape
                        .stroke(LadleTheme.Label.primary.opacity(0.08), lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account.privacy")
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            LadleSectionHeader(
                title: "Appearance",
                detail: "Accent color"
            )

            HStack(spacing: LadleTheme.Spacing.compact) {
                ForEach(LadleAccentColor.allCases) { accent in
                    Button {
                        accentColor = accent.rawValue
                    } label: {
                        ZStack {
                            Circle()
                                .fill(accent.actionColor)
                            if selectedAccent == accent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: LadleTheme.IconSize.small, weight: .bold))
                                    .foregroundStyle(LadleTheme.Label.onAccent)
                            }
                        }
                        .frame(width: LadleTheme.Control.hitTarget, height: LadleTheme.Control.hitTarget)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LadlePressButtonStyle())
                    .accessibilityLabel(accent.title)
                    .accessibilityValue(
                        selectedAccent == accent ? "Selected" : ""
                    )
                }
            }
            .padding(LadleTheme.Spacing.medium)
            .background(LadleTheme.Surface.raised, in: accountShape)
            .overlay {
                accountShape
                    .stroke(LadleTheme.Label.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .sensoryFeedback(.selection, trigger: accentColor)
    }

    private var accountActionsSection: some View {
        VStack(alignment: .leading, spacing: LadleTheme.Spacing.medium) {
            LadleSectionHeader(title: "Account actions")

            VStack(spacing: 0) {
                Button {
                    isSignOutConfirmationPresented = true
                } label: {
                    accountActionRow(
                        icon: "rectangle.portrait.and.arrow.right",
                        title: "Sign out",
                        detail: "Keep your synced library in Overeasy.",
                        isLoading: isSigningOut
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSigningOut || isDeletingAccount)
                .accessibilityIdentifier("account.sign-out")

                accountDivider

                Button(role: .destructive) {
                    isDeleteConfirmationPresented = true
                } label: {
                    accountActionRow(
                        icon: "trash",
                        title: "Delete account",
                        detail: "Permanently remove account data and recipes.",
                        isDestructive: true,
                        isLoading: isDeletingAccount
                    )
                }
                .buttonStyle(.plain)
                .disabled(isDeletingAccount || isSigningOut)
                .accessibilityIdentifier("account.delete")
            }
            .background(LadleTheme.Surface.raised, in: accountShape)
            .overlay {
                accountShape
                    .stroke(LadleTheme.Label.primary.opacity(0.08), lineWidth: 1)
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
                "Your synced recipes and account data will be permanently deleted. This can’t be undone."
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

    private var accountStatus: String {
        switch accountSession.state {
        case .undecided: "Not connected"
        case .guest: "Guest"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle: "Connected"
        }
    }

    private var accountStatusSymbol: String {
        switch accountSession.state {
        case .undecided: "exclamationmark.circle"
        case .guest: "iphone"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            "checkmark.circle.fill"
        }
    }

    private var accountStatusTint: Color {
        switch accountSession.state {
        case .undecided: LadleTheme.Surface.steel
        case .guest: LadleTheme.Surface.steel
        case .freeAccount, .signedInWithApple, .signedInWithGoogle:
            LadleTheme.Intent.success
        }
    }

    private var accountDivider: some View {
        Divider()
            .overlay(LadleTheme.Label.primary.opacity(0.08))
            .padding(
                .leading,
                LadleTheme.dividerInset(
                    iconWidth: Self.rowIconWidth,
                    leadingPadding: LadleTheme.Layout.cardPadding
                )
            )
    }

    private func infoRow(
        icon: String,
        title: String,
        value: String
    ) -> some View {
        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
            spacing: LadleTheme.Layout.iconGap
        ) {
            Image(systemName: icon)
                .font(.system(size: LadleTheme.IconSize.medium, weight: .semibold))
                .foregroundStyle(accent.label)
                .frame(width: Self.rowIconWidth, height: Self.rowIconWidth)
                .background(LadleTheme.Surface.badge, in: Circle())

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                    infoTitle(title)
                    infoValue(value)
                }
            } else {
                infoTitle(title)
                Spacer(minLength: LadleTheme.Spacing.compact)
                infoValue(value)
            }
        }
        .padding(.horizontal, LadleTheme.Layout.cardPadding)
        .padding(.vertical, LadleTheme.Spacing.medium)
        .frame(minHeight: LadleTheme.Control.primary)
        .accessibilityElement(children: .combine)
    }

    private func infoTitle(_ title: String) -> some View {
        Text(title)
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.Label.primary)
    }

    private func infoValue(_ value: String) -> some View {
        Text(value)
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.Label.primary.opacity(0.75))
    }

    private func accountActionRow(
        icon: String,
        title: String,
        detail: String,
        isDestructive: Bool = false,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: LadleTheme.Layout.iconGap) {
            Image(systemName: icon)
                .font(.system(size: LadleTheme.IconSize.medium, weight: .semibold))
                .foregroundStyle(
                    isDestructive ? Color.red : LadleTheme.Label.primary
                )
                .frame(width: Self.rowIconWidth, height: Self.rowIconWidth)
                .background(LadleTheme.Surface.badge, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LadleTheme.Spacing.tight) {
                Text(title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(
                        isDestructive ? Color.red : LadleTheme.Label.primary
                    )
                Text(detail)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: LadleTheme.Spacing.compact)

            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: LadleTheme.IconSize.small, weight: .semibold))
                    .foregroundStyle(LadleTheme.Label.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, LadleTheme.Layout.cardPadding)
        .padding(.vertical, LadleTheme.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Width of a row's leading icon badge. `accountDivider` derives its
    /// inset from this so the divider tracks the label origin instead of
    /// restating it as a literal that nothing keeps in step.
    private static let rowIconWidth: CGFloat = 34

    private var accountShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: LadleTheme.Corner.control,
            style: .continuous
        )
    }

    private var selectedAccent: LadleAccentColor {
        LadleAccentColor.resolve(storedValue: accentColor)
    }

}
