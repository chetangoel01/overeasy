import SwiftUI

struct AccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(LadleAccentColor.preferenceKey)
    private var accentColor = LadleAccentColor.tomato.rawValue

    let accountSession: AccountSession
    let library: LibraryViewModel
    let signOut: @MainActor () async -> Void
    let deleteAccount: @MainActor () async throws -> Void

    @State private var isSignOutConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isSigningOut = false
    @State private var isDeletingAccount = false
    @State private var deletionErrorMessage: String?

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
            .background(LadleTheme.paper)
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
        .presentationBackground(LadleTheme.paper)
    }

    private var accountSummary: some View {
        HStack(alignment: .top, spacing: LadleTheme.Spacing.regular) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 52, height: 52)
                .background(LadleTheme.Surface.steel, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: LadleTheme.Spacing.compact) {
                Text(Self.accountTitle(for: accountSession.state))
                    .ladleFont(.section)
                    .foregroundStyle(LadleTheme.ink)

                Text(Self.accountDetail(for: accountSession.state))
                    .ladleFont(.body)
                    .foregroundStyle(LadleTheme.mutedInk)
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
                .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
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
                    value: Self.syncValue(for: accountSession.state)
                )
            }
            .background(LadleTheme.Surface.raised, in: accountShape)
            .overlay {
                accountShape
                    .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
            }
        }
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LadleSectionHeader(title: "Privacy")

            NavigationLink {
                PrivacyDetailView()
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "hand.raised")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(LadleTheme.paprika)
                        .frame(width: 34, height: 34)
                        .background(LadleTheme.Surface.steel, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Privacy & data")
                            .ladleFont(.body)
                            .foregroundStyle(LadleTheme.ink)
                        Text("What Overeasy stores, and what it never does")
                            .ladleFont(.metadata)
                            .foregroundStyle(LadleTheme.mutedInk)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LadleTheme.mutedInk)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(minHeight: 56)
                .background(LadleTheme.Surface.raised, in: accountShape)
                .overlay {
                    accountShape
                        .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
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
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(LadleTheme.onAccent)
                            }
                        }
                        .frame(width: 44, height: 44)
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
                    .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
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
                .disabled(isSigningOut)
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
                .disabled(isDeletingAccount)
                .accessibilityIdentifier("account.delete")
            }
            .background(LadleTheme.Surface.raised, in: accountShape)
            .overlay {
                accountShape
                    .stroke(LadleTheme.ink.opacity(0.08), lineWidth: 1)
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
                get: { deletionErrorMessage != nil },
                set: { if !$0 { deletionErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(
                deletionErrorMessage
                    ?? "Please check your connection and try again."
            )
        }
    }

    private func performSignOut() {
        guard !isSigningOut else {
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
        guard !isDeletingAccount else {
            return
        }
        isDeletingAccount = true
        Task { @MainActor in
            do {
                try await deleteAccount()
                dismiss()
            } catch {
                isDeletingAccount = false
                deletionErrorMessage =
                    "Please check your connection and try again."
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

    static func syncValue(for state: AccountState) -> String {
        switch state {
        case .undecided, .guest: "This device"
        case .freeAccount, .signedInWithApple, .signedInWithGoogle: "On"
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
            .overlay(LadleTheme.ink.opacity(0.08))
            .padding(.leading, 61)
    }

    private func infoRow(
        icon: String,
        title: String,
        value: String
    ) -> some View {
        HStack(
            alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center,
            spacing: 13
        ) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(LadleTheme.paprika)
                .frame(width: 34, height: 34)
                .background(LadleTheme.Surface.steel, in: Circle())

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    infoTitle(title)
                    infoValue(value)
                }
            } else {
                infoTitle(title)
                Spacer(minLength: LadleTheme.Spacing.compact)
                infoValue(value)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private func infoTitle(_ title: String) -> some View {
        Text(title)
            .ladleFont(.body)
            .foregroundStyle(LadleTheme.ink)
    }

    private func infoValue(_ value: String) -> some View {
        Text(value)
            .ladleFont(.bodyStrong)
            .foregroundStyle(LadleTheme.ink.opacity(0.75))
    }

    private func accountActionRow(
        icon: String,
        title: String,
        detail: String,
        isDestructive: Bool = false,
        isLoading: Bool
    ) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(
                    isDestructive ? Color.red : LadleTheme.ink
                )
                .frame(width: 34, height: 34)
                .background(LadleTheme.Surface.steel, in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ladleFont(.bodyStrong)
                    .foregroundStyle(
                        isDestructive ? Color.red : LadleTheme.ink
                    )
                Text(detail)
                    .ladleFont(.metadata)
                    .foregroundStyle(LadleTheme.mutedInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: LadleTheme.Spacing.compact)

            if isLoading {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LadleTheme.mutedInk)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

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
